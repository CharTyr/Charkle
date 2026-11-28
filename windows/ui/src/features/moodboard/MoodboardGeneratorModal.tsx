import React, { useEffect, useMemo, useState } from 'react';
import {
  ArrowSync16Regular,
  Checkmark16Regular,
  CheckmarkCircle16Filled,
  Color16Regular,
  Cube16Regular,
  Dismiss16Regular,
  DocumentText16Regular,
  Filmstrip16Regular,
  Globe16Regular,
  Image16Regular,
  MusicNote216Regular,
  Options16Regular,
  Search16Regular,
  Sparkle16Regular,
  Wand16Regular,
  Warning16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleSlider,
  FILTER_PRESET_COLORS,
  isLightHex,
  ModalShell,
  SegmentedControl,
} from '../../design-system';
import {
  getSubtreeFolderIds,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../../stores';
import type {
  AssetRecord,
  EditorialStyle,
  LabColor,
  MoodboardCurationRequest,
  MoodboardDocument,
} from '../../types/domain';

type GeneratorEntryTab = 'prompt' | 'seeds' | 'palette' | 'manual' | 'combined';

const PRESET_PROMPTS: ReadonlyArray<string> = [
  '夏日清凉插画与通透蓝天阳光',
  '极简暖调陶艺、纸张肌理与自然光影',
  '瑞士网格排版与编辑部视觉',
  '暗色数据界面与克制质感',
];

function hexToApproxLab(hex: string): LabColor {
  const clean = hex.replace('#', '');
  const r = parseInt(clean.slice(0, 2), 16) / 255;
  const g = parseInt(clean.slice(2, 4), 16) / 255;
  const b = parseInt(clean.slice(4, 6), 16) / 255;
  const l = (0.299 * r + 0.587 * g + 0.114 * b) * 100;
  const a = (r - g) * 80;
  const bl = (g - b) * 80;
  return { hex: hex.toUpperCase(), l, a, b: bl, proportion: 0.5 };
}

function withCacheBust(url: string, updatedAt: number | string | undefined): string {
  if (!url || url.startsWith('data:') || url.startsWith('blob:') || updatedAt === undefined) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(updatedAt))}`;
}

function renderMediaFallbackIcon(kind: AssetRecord['mediaKind']) {
  switch (kind) {
    case 'video':
    case 'animatedImage':
      return <Filmstrip16Regular className="w-5 h-5" />;
    case 'audio':
      return <MusicNote216Regular className="w-5 h-5" />;
    case 'document':
      return <DocumentText16Regular className="w-5 h-5" />;
    case 'webBookmark':
      return <Globe16Regular className="w-5 h-5" />;
    case 'model3D':
      return <Cube16Regular className="w-5 h-5" />;
    default:
      return <Image16Regular className="w-5 h-5" />;
  }
}

interface PickerAssetTileProps {
  asset: AssetRecord;
  selected: boolean;
  onToggle: () => void;
}

const PickerAssetTile: React.FC<PickerAssetTileProps> = ({ asset, selected, onToggle }) => {
  const transport = getTransport();
  const isSwatch = asset.fileName.toLowerCase().endsWith('.swatch');
  const rawThumb = isSwatch ? '' : transport.thumbnailUrl(asset.id, 'grid520');
  const thumbUrl = withCacheBust(rawThumb, asset.updatedAt);
  const [imgFailed, setImgFailed] = useState(false);

  useEffect(() => {
    setImgFailed(false);
  }, [thumbUrl]);

  const primaryHex = asset.dominantColors?.[0]?.hex?.trim() || null;
  const secondaryHex = asset.dominantColors?.[1]?.hex?.trim() || null;
  const swatchHex = (primaryHex || '#64748B').toUpperCase();
  const swatchLight = isLightHex(swatchHex);
  const displayTitle = asset.title || asset.fileName || '未命名素材';

  const backdropStyle: React.CSSProperties = isSwatch
    ? { backgroundColor: swatchHex }
    : primaryHex && secondaryHex
      ? { backgroundImage: `linear-gradient(135deg, ${primaryHex}40 0%, ${secondaryHex}2C 100%)` }
      : primaryHex
        ? { backgroundColor: `${primaryHex}33` }
        : {};

  return (
    <button
      type="button"
      aria-pressed={selected}
      data-picker-asset-id={asset.id}
      title={displayTitle}
      onClick={onToggle}
      style={backdropStyle}
      className={[
        'group relative w-full h-[92px] rounded-[var(--radius-card-inner)] overflow-hidden bg-[var(--bg-elevated)] border cursor-pointer text-left select-none transition-colors duration-150',
        selected
          ? 'border-[var(--accent)] ring-2 ring-[var(--accent)]'
          : 'border-[var(--border-hairline)] hover:border-[var(--border-strong)]',
      ].join(' ')}
    >
      {isSwatch ? (
        <div className="w-full h-full flex flex-col items-center justify-center px-1.5 pb-3">
          <span
            style={{ color: swatchLight ? 'rgba(0,0,0,0.78)' : 'rgba(255,255,255,0.92)' }}
            className="text-[11px] font-semibold charkle-mono tracking-tight"
          >
            {swatchHex}
          </span>
        </div>
      ) : !imgFailed && thumbUrl ? (
        <img
          src={thumbUrl}
          alt={displayTitle}
          loading="lazy"
          draggable={false}
          onError={() => setImgFailed(true)}
          className="w-full h-full object-cover"
        />
      ) : (
        <div className="w-full h-full flex flex-col items-center justify-center gap-1 px-2 pb-4 text-[var(--text-secondary)]">
          {renderMediaFallbackIcon(asset.mediaKind)}
        </div>
      )}

      {/* Subtle bottom title scrim (always legible over images & fallbacks) */}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 px-1.5 py-1 bg-gradient-to-t from-black/72 via-black/42 to-transparent">
        <div className="text-[10px] font-medium text-white truncate leading-tight">
          {displayTitle}
        </div>
      </div>

      {/* Crisp top-right selection badge */}
      <span
        aria-hidden="true"
        className={[
          'pointer-events-none absolute top-1.5 right-1.5 h-5 w-5 rounded-full inline-flex items-center justify-center transition-opacity duration-150',
          selected
            ? 'bg-[var(--accent)] text-[var(--accent-text)] ring-1.5 ring-white/90 shadow-sm opacity-100'
            : 'bg-black/32 border border-white/80 text-transparent opacity-0 group-hover:opacity-100',
        ].join(' ')}
      >
        <Checkmark16Regular className="w-3 h-3" />
      </span>
    </button>
  );
};

export interface MoodboardGeneratorModalProps {
  open: boolean;
  onClose: () => void;
  existingBoard?: MoodboardDocument | null;
}

export const MoodboardGeneratorModal: React.FC<MoodboardGeneratorModalProps> = ({
  open,
  onClose,
  existingBoard = null,
}) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const selectedLibraryIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const openSettings = useCoordinatorStore((s) => s.openSettings);

  const allLibraryAssets = useLibraryStore((s) => s.allAssets);
  const filteredLibraryAssets = useLibraryStore((s) => s.assets);
  const libraryBootstrapped = useLibraryStore((s) => s.bootstrapped);
  const assets = allLibraryAssets.length > 0 ? allLibraryAssets : filteredLibraryAssets;
  const folders = useLibraryStore((s) => s.folders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);

  const aiState = useSyncAIStore((s) => s.aiState);
  const typesafeState = useSyncAIStore((s) => s.typesafeState);

  const curating = useMoodboardStore((s) => s.curating);
  const agentTrace = useMoodboardStore((s) => s.agentTrace);
  const curateMoodboard = useMoodboardStore((s) => s.curateMoodboard);

  const [tab, setTab] = useState<GeneratorEntryTab>('prompt');
  const [prompt, setPrompt] = useState('');
  const [seedAssetIds, setSeedAssetIds] = useState<string[]>([]);
  const [selectedHexes, setSelectedHexes] = useState<string[]>([]);
  const [colorTolerance, setColorTolerance] = useState(26);
  const [scopeFolderIds, setScopeFolderIds] = useState<string[]>([]);
  const [requiredTags, setRequiredTags] = useState<string[]>([]);
  const [preferredCount, setPreferredCount] = useState(10);
  const [layoutStyle, setLayoutStyle] = useState<EditorialStyle>('magazine');
  const [useFreeformLayout, setUseFreeformLayout] = useState(true);
  const [includeCuratorNotes, setIncludeCuratorNotes] = useState(true);
  const [autoFocusDetailCrop, setAutoFocusDetailCrop] = useState(false);
  const [pickerQuery, setPickerQuery] = useState('');
  const [localError, setLocalError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setTab('prompt');
    setPrompt('');
    setSelectedHexes([]);
    setRequiredTags([]);
    setPickerQuery('');
    setLocalError(null);
    const lib = useLibraryStore.getState();
    const currentPool = lib.allAssets.length > 0 ? lib.allAssets : lib.assets;
    const validIds = new Set(currentPool.filter((a) => !a.isTrashed).map((a) => a.id));
    if (currentPool.length === 0) {
      void lib.refreshAll(destination);
    }
    setSeedAssetIds(
      selectedLibraryIds.length > 0
        ? selectedLibraryIds.filter((id) => validIds.has(id)).slice(0, 4)
        : [],
    );
    setScopeFolderIds(destination.type === 'folder' ? [destination.id] : []);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const nonTrashedAssetCount = useMemo(
    () => assets.filter((a) => !a.isTrashed).length,
    [assets],
  );
  const isLibraryEmpty = libraryBootstrapped && nonTrashedAssetCount === 0;

  const pickableAssets = useMemo(() => {
    const allowedFolders =
      scopeFolderIds.length > 0
        ? new Set(scopeFolderIds.flatMap((fid) => getSubtreeFolderIds(folders, fid)))
        : null;
    const reqTagsLower = requiredTags.map((t) => t.toLowerCase());
    const q = pickerQuery.trim().toLowerCase();

    return assets
      .filter((a) => {
        if (a.isTrashed) return false;
        if (allowedFolders && (!a.folderID || !allowedFolders.has(a.folderID))) {
          return false;
        }
        if (reqTagsLower.length > 0) {
          const assetTags = (a.tags ?? []).map((t) => t.toLowerCase());
          if (!reqTagsLower.every((rt) => assetTags.includes(rt))) return false;
        }
        if (q) {
          const haystack = [
            a.title,
            a.fileName,
            a.sourceDomain ?? '',
            a.notes ?? '',
            ...(a.tags ?? []),
          ]
            .join(' ')
            .toLowerCase();
          if (!haystack.includes(q)) return false;
        }
        return true;
      })
      .slice(0, 240);
  }, [assets, folders, scopeFolderIds, requiredTags, pickerQuery]);

  const hasPickerScopeFilter =
    scopeFolderIds.length > 0 || requiredTags.length > 0 || pickerQuery.trim().length > 0;

  const isTypeSafeReady = Boolean(typesafeState?.config.enabled && typesafeState?.hasApiKey);
  const isCloudAIReady = Boolean(
    (aiState && aiState.config.provider !== 'disabled' && aiState.hasApiKey) || isTypeSafeReady,
  );
  const providerBadge = useMemo(() => {
    const hasGen = Boolean(aiState && aiState.config.provider !== 'disabled' && aiState.hasApiKey);
    if (!hasGen && isTypeSafeReady) return '视觉策展';
    if (!hasGen) return '本机离线模式';
    switch (aiState?.config.provider) {
      case 'chatGPTSubscription':
        return 'ChatGPT 视觉策展';
      case 'gemini':
        return 'Gemini 视觉策展';
      case 'openAICompatible':
        return '云端模型视觉策展';
      default:
        return '本机离线模式';
    }
  }, [aiState, isTypeSafeReady]);

  const toggleItem = (list: string[], id: string, setter: (v: string[]) => void) => {
    setter(list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
  };

  const handleGenerate = async () => {
    setLocalError(null);
    if (isLibraryEmpty) {
      setLocalError('素材库中还没有可用素材，请先导入图片后再生成情绪板');
      return;
    }
    if (tab === 'manual' && seedAssetIds.length === 0) {
      setLocalError('请至少勾选 1 项素材后再生成情绪板');
      return;
    }
    if (tab === 'seeds' && seedAssetIds.length === 0) {
      setLocalError('请至少点选 1 张定调种子图');
      return;
    }
    if (tab === 'palette' && selectedHexes.length === 0) {
      setLocalError('请至少选择 1 个色彩倾向');
      return;
    }
    const req: MoodboardCurationRequest = {
      prompt: tab === 'palette' || tab === 'manual' ? '' : prompt.trim(),
      seedAssetIDs: tab === 'prompt' || tab === 'palette' ? [] : seedAssetIds,
      scopeFolderIDs: scopeFolderIds,
      requiredTags,
      targetPalette:
        tab === 'palette' || tab === 'combined' ? selectedHexes.map(hexToApproxLab) : [],
      colorTolerance,
      preferredCount:
        tab === 'manual' && seedAssetIds.length > 0 ? seedAssetIds.length : preferredCount,
      candidateCount: 24,
      layoutStyle,
      useFreeformLayout,
      includeCuratorNotes,
      excludedAssetIDs: [],
      lockedAssetIDs: tab === 'manual' ? seedAssetIds : [],
      existingBoard,
      refinementInstruction: null,
      autoFocusDetailCrop: autoFocusDetailCrop && isTypeSafeReady,
    };
    try {
      await curateMoodboard(req);
      onClose();
    } catch (err) {
      setLocalError(err instanceof Error ? err.message : String(err));
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      title={existingBoard ? 'AI 情绪板策展微调' : 'AI 情绪板策展工作台'}
      subtitle="组合灵感词、目录与种子图，智能筛选并编排分区"
      width="lg"
      headerRight={
        <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] text-[11px] text-[var(--text-secondary)]">
          <span
            className={[
              'h-1.5 w-1.5 rounded-full',
              isCloudAIReady ? 'bg-[var(--success)]' : 'bg-[var(--warning)]',
            ].join(' ')}
          />
          <span>{providerBadge}</span>
          {!isCloudAIReady && (
            <button
              type="button"
              onClick={() => {
                onClose();
                openSettings('ai');
              }}
              className="ml-0.5 text-[var(--accent)] font-medium hover:underline cursor-pointer"
            >
              去开启
            </button>
          )}
        </div>
      }
      footer={
        <>
          <Button variant="standard" onClick={onClose}>
            取消
          </Button>
          <Button
            variant="accent"
            loading={curating}
            disabled={isLibraryEmpty}
            onClick={() => void handleGenerate()}
          >
            <Sparkle16Regular className="w-3.5 h-3.5" />
            立即生成情绪板
          </Button>
        </>
      }
    >
      <div data-testid="moodboard-generator-modal" className="flex flex-col gap-4">
        <SegmentedControl<GeneratorEntryTab>
          value={tab}
          onChange={(nextTab) => {
            setTab(nextTab);
            setLocalError(null);
          }}
          ariaLabel="策展入口"
          options={[
            { value: 'prompt', label: '灵感主题词', icon: <Wand16Regular className="w-3.5 h-3.5" /> },
            { value: 'seeds', label: '定调种子图', icon: <Image16Regular className="w-3.5 h-3.5" /> },
            { value: 'palette', label: '色彩倾向', icon: <Color16Regular className="w-3.5 h-3.5" /> },
            { value: 'manual', label: '手动挑选' },
            { value: 'combined', label: '综合组合', icon: <Options16Regular className="w-3.5 h-3.5" /> },
          ]}
        />

        {isLibraryEmpty && (
          <div className="p-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)] text-[11.5px] text-[var(--text-secondary)] flex items-center gap-2">
            <Warning16Regular className="w-3.5 h-3.5 text-[var(--warning)] shrink-0" />
            <span>当前素材库暂无可用素材，请先导入图片后再生成情绪板。</span>
          </div>
        )}

        {/* Prompt Input + Preset Chips */}
        {(tab === 'prompt' || tab === 'combined') && (
          <div className="flex flex-col gap-2">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">
              灵感方向与要求
            </label>
            <input
              type="text"
              value={prompt}
              autoFocus
              onChange={(e) => {
                setLocalError(null);
                setPrompt(e.target.value);
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.nativeEvent.isComposing && !curating) {
                  void handleGenerate();
                }
              }}
              placeholder="例如：暖石膏建筑、低角度晨光阴影、瑞士极简杂志排版…"
              className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[13px] text-[var(--text-primary)] outline-none"
            />
            <div className="flex items-center gap-1.5 flex-wrap">
              {PRESET_PROMPTS.map((sample) => (
                <button
                  key={sample}
                  type="button"
                  onClick={() => setPrompt(sample)}
                  className="charkle-pressable win-control-elevation px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  {sample}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Seed / Manual Asset Picker */}
        {(tab === 'seeds' || tab === 'manual' || tab === 'combined') && (
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between gap-2 text-[12px]">
              <span className="font-medium text-[var(--text-secondary)]">
                {tab === 'manual' ? '勾选要放入情绪板的素材' : '点选 1–4 张定调种子图'}
              </span>
              <div className="flex items-center gap-2">
                <span className="text-[var(--text-tertiary)] charkle-tabular">
                  已选 {seedAssetIds.length} 项 · 可选 {pickableAssets.length} 项
                </span>
                {seedAssetIds.length > 0 && (
                  <button
                    type="button"
                    onClick={() => setSeedAssetIds([])}
                    className="text-[11px] font-medium text-[var(--accent)] hover:underline cursor-pointer"
                  >
                    清空已选
                  </button>
                )}
              </div>
            </div>

            <div className="relative flex items-center">
              <Search16Regular className="w-3.5 h-3.5 absolute left-2.5 text-[var(--text-tertiary)] pointer-events-none" />
              <input
                type="text"
                value={pickerQuery}
                onChange={(e) => setPickerQuery(e.target.value)}
                placeholder="筛选素材标题或标签…"
                aria-label="筛选可选素材"
                className="win-input-elevation w-full h-8 pl-8 pr-7 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
              />
              {pickerQuery && (
                <button
                  type="button"
                  aria-label="清空素材筛选词"
                  onClick={() => setPickerQuery('')}
                  className="absolute right-2 h-4.5 w-4.5 rounded-full hover:bg-[var(--win-subtle-hover)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer"
                >
                  <Dismiss16Regular className="w-3 h-3" />
                </button>
              )}
            </div>

            {pickableAssets.length === 0 ? (
              <div
                data-testid="moodboard-picker-empty"
                className="min-h-[132px] rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)]/70 border border-[var(--win-stroke-card)] p-4 flex flex-col items-center justify-center gap-2 text-center"
              >
                <Image16Regular className="w-5 h-5 text-[var(--text-tertiary)]" />
                <div className="text-[12px] text-[var(--text-secondary)]">
                  {hasPickerScopeFilter ? '当前筛选条件下没有可选素材' : '素材库中还没有可用素材'}
                </div>
                {hasPickerScopeFilter && (
                  <button
                    type="button"
                    onClick={() => {
                      setScopeFolderIds([]);
                      setRequiredTags([]);
                      setPickerQuery('');
                    }}
                    className="charkle-pressable win-control-elevation px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--accent)] cursor-pointer"
                  >
                    清除筛选条件
                  </button>
                )}
              </div>
            ) : (
              <div
                data-testid="moodboard-asset-picker-grid"
                className="grid grid-cols-4 sm:grid-cols-5 gap-2 max-h-[240px] overflow-y-auto charkle-scroll p-2 rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)]/70 border border-[var(--win-stroke-card)]"
              >
                {pickableAssets.map((a) => (
                  <PickerAssetTile
                    key={a.id}
                    asset={a}
                    selected={seedAssetIds.includes(a.id)}
                    onToggle={() => {
                      setLocalError(null);
                      toggleItem(seedAssetIds, a.id, setSeedAssetIds);
                    }}
                  />
                ))}
              </div>
            )}
          </div>
        )}

        {/* Color Direction Picker */}
        {(tab === 'palette' || tab === 'combined') && (
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between text-[12px]">
              <span className="font-medium text-[var(--text-secondary)]">色彩倾向</span>
              <span className="text-[11.5px] text-[var(--text-tertiary)] charkle-tabular">
                匹配范围 {colorTolerance}
              </span>
            </div>
            <div className="flex items-center gap-2 flex-wrap">
              {FILTER_PRESET_COLORS.map((hex) => {
                const active = selectedHexes.includes(hex);
                return (
                  <button
                    key={hex}
                    type="button"
                    aria-label={`选择主色 ${hex}`}
                    onClick={() => {
                      setLocalError(null);
                      toggleItem(selectedHexes, hex, setSelectedHexes);
                    }}
                    className={[
                      'charkle-pressable h-7 w-7 rounded-full border border-black/15 cursor-pointer',
                      active ? 'ring-2 ring-offset-2 ring-[var(--accent)]' : '',
                    ].join(' ')}
                    style={{ backgroundColor: hex }}
                  />
                );
              })}
            </div>
            <CharkleSlider
              min={12}
              max={46}
              step={2}
              value={colorTolerance}
              onChange={setColorTolerance}
              ariaLabel="色彩匹配范围"
              valueText={`${colorTolerance}`}
              variant="standard"
              size="sm"
              className="w-full"
            />
          </div>
        )}

        {/* Folder & Tag Scope */}
        {(folders.length > 0 || tagCounts.length > 0) && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-1 border-t border-[var(--win-stroke-divider)]">
            {folders.length > 0 && (
              <div className="flex flex-col gap-1.5">
                <span className="text-[11.5px] font-medium text-[var(--text-tertiary)]">
                  限定文件夹范围（留空为全库）
                </span>
                <div className="flex flex-wrap gap-1">
                  {folders.slice(0, 8).map((f) => {
                    const active = scopeFolderIds.includes(f.id);
                    return (
                      <button
                        key={f.id}
                        type="button"
                        onClick={() => toggleItem(scopeFolderIds, f.id, setScopeFolderIds)}
                        className={[
                          'charkle-pressable h-6 px-2 rounded-[var(--win-radius-control)] text-[11.5px] cursor-pointer',
                          active
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                            : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
                        ].join(' ')}
                      >
                        {f.name}
                      </button>
                    );
                  })}
                </div>
              </div>
            )}

            {tagCounts.length > 0 && (
              <div className="flex flex-col gap-1.5">
                <span className="text-[11.5px] font-medium text-[var(--text-tertiary)]">
                  必含标签（可选）
                </span>
                <div className="flex flex-wrap gap-1">
                  {tagCounts.slice(0, 8).map((t) => {
                    const active = requiredTags.includes(t.name);
                    return (
                      <button
                        key={t.name}
                        type="button"
                        onClick={() => toggleItem(requiredTags, t.name, setRequiredTags)}
                        className={[
                          'charkle-pressable h-6 px-2 rounded-[var(--win-radius-control)] text-[11.5px] cursor-pointer',
                          active
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                            : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
                        ].join(' ')}
                      >
                        #{t.name}
                      </button>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Layout Style & Count */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-2 border-t border-[var(--win-stroke-divider)]">
          <div className="flex flex-col gap-1.5">
            <span className="text-[11.5px] font-medium text-[var(--text-tertiary)]">初始构图节奏</span>
            <SegmentedControl<EditorialStyle>
              value={layoutStyle}
              onChange={setLayoutStyle}
              options={[
                { value: 'magazine', label: '杂志' },
                { value: 'balanced', label: '均衡' },
                { value: 'compact', label: '紧凑' },
              ]}
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <div className="flex items-center justify-between text-[11.5px]">
              <span className="font-medium text-[var(--text-tertiary)]">数量上限</span>
              <span className="charkle-tabular text-[var(--text-secondary)]">{preferredCount} 张</span>
            </div>
            <CharkleSlider
              min={6}
              max={20}
              step={1}
              value={preferredCount}
              onChange={setPreferredCount}
              ariaLabel="数量上限"
              valueText={`${preferredCount} 张`}
              variant="standard"
              size="sm"
              className="w-full"
            />
          </div>
        </div>

        <div className="flex items-center gap-4 flex-wrap text-[12px] text-[var(--text-primary)]">
          <label className="inline-flex items-center gap-1.5 cursor-pointer">
            <input
              type="checkbox"
              checked={useFreeformLayout}
              onChange={(e) => setUseFreeformLayout(e.target.checked)}
              className="accent-[var(--accent)]"
            />
            直接进入自由画布
          </label>
          <label className="inline-flex items-center gap-1.5 cursor-pointer">
            <input
              type="checkbox"
              checked={includeCuratorNotes}
              onChange={(e) => setIncludeCuratorNotes(e.target.checked)}
              className="accent-[var(--accent)]"
            />
            附带视觉策展便签与分区标题
          </label>
          <label
            className={[
              'inline-flex items-center gap-1.5',
              isTypeSafeReady ? 'cursor-pointer' : 'opacity-50 cursor-not-allowed',
            ].join(' ')}
            title={isTypeSafeReady ? '入选主图会自动按灵感词定位局部细节' : '需在设置中开启视觉定位增强'}
          >
            <input
              type="checkbox"
              disabled={!isTypeSafeReady}
              checked={autoFocusDetailCrop && isTypeSafeReady}
              onChange={(e) => setAutoFocusDetailCrop(e.target.checked)}
              className="accent-[var(--accent)]"
            />
            细节特写模式
          </label>
        </div>

        {localError && (
          <div className="p-2.5 rounded-[var(--win-radius-control)] bg-[var(--warning-soft)] text-[11.5px] text-[var(--text-primary)] flex items-center gap-2">
            <Warning16Regular className="w-3.5 h-3.5 text-[var(--warning)] shrink-0" />
            <span>{localError}</span>
          </div>
        )}

        {/* Live Agent Trace */}
        {agentTrace.length > 0 && (
          <div
            data-testid="agent-harness-trace"
            className="p-3 rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)] flex flex-col gap-1.5"
          >
            <div className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
              策展步骤（{agentTrace.length} 步）
            </div>
            {agentTrace.map((step) => (
              <div key={step.id} className="flex items-start gap-2 text-[11.5px]">
                {step.status === 'done' ? (
                  <CheckmarkCircle16Filled className="w-3.5 h-3.5 text-[var(--success)] shrink-0 mt-0.5" />
                ) : step.status === 'warning' ? (
                  <Warning16Regular className="w-3.5 h-3.5 text-[var(--warning)] shrink-0 mt-0.5" />
                ) : (
                  <ArrowSync16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0 mt-0.5 animate-spin motion-reduce:animate-none" />
                )}
                <div className="min-w-0">
                  <span className="font-medium text-[var(--text-primary)]">{step.title}</span>
                  {step.detail && (
                    <span className="text-[var(--text-tertiary)] ml-1.5">{step.detail}</span>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </ModalShell>
  );
};
