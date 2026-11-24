import React, { useEffect, useMemo, useState } from 'react';
import { Checkmark12Regular, Dismiss12Regular } from '@fluentui/react-icons';
import {
  Button,
  CharkleIcon,
  CharkleSlider,
  ModalShell,
  SegmentedControl,
} from '../../design-system';
import {
  getSmartFolderMatchCount,
  getTopTenSidebarTags,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  mediaKindLabel,
  msToCocoaSeconds,
  type MediaKind,
  type SmartFolderMatchMode,
  type SmartFolderRecord,
  type SmartFolderRule,
  type TagCount,
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

const QUICK_PALETTE: readonly string[] = [
  '#E11D48',
  '#F97316',
  '#F59E0B',
  '#10B981',
  '#06B6D4',
  '#3B82F6',
  '#1D4ED8',
  '#EC4899',
  '#18181B',
  '#71717A',
  '#E4E4E7',
  '#FFFFFF',
];

function isLightHex(hex: string): boolean {
  const c = hex.replace('#', '');
  if (c.length !== 6) return false;
  const r = parseInt(c.slice(0, 2), 16);
  const g = parseInt(c.slice(2, 4), 16);
  const b = parseInt(c.slice(4, 6), 16);
  return 0.299 * r + 0.587 * g + 0.114 * b > 175;
}

function makeId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().toUpperCase();
  }
  return `SF-${Date.now()}`;
}

export interface SmartFolderEditorModalProps {
  open: boolean;
  onClose: () => void;
  initial?: SmartFolderRecord | null;
  availableTags: TagCount[];
  onSave: (folder: SmartFolderRecord) => Promise<void> | void;
}

/**
 * Fluent 2 Smart Folder rule builder with live match count,
 * removable tag chips, multi-color tolerance picker, media kinds, and rating filter.
 */
export const SmartFolderEditorModal: React.FC<SmartFolderEditorModalProps> = ({
  open,
  onClose,
  initial,
  availableTags,
  onSave,
}) => {
  const allAssets = useLibraryStore((s) => s.allAssets);
  const smartFoldersCount = useLibraryStore((s) => s.smartFolders.length);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [name, setName] = useState('');
  const [matchMode, setMatchMode] = useState<SmartFolderMatchMode>('all');
  const [selectedTags, setSelectedTags] = useState<string[]>([]);
  const [customTagInput, setCustomTagInput] = useState('');
  const [descriptionQuery, setDescriptionQuery] = useState('');
  const [colorHexes, setColorHexes] = useState<string[]>([]);
  const [colorTolerance, setColorTolerance] = useState(24);
  const [customColorHex, setCustomColorHex] = useState('#3B82F6');
  const [mediaKinds, setMediaKinds] = useState<MediaKind[]>([]);
  const [minRating, setMinRating] = useState(0);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    if (initial) {
      setName(initial.name);
      setMatchMode(initial.rule.matchMode);
      setSelectedTags([...initial.rule.tags]);
      setCustomTagInput('');
      setDescriptionQuery(initial.rule.descriptionQuery);
      setColorHexes([...initial.rule.colorHexes]);
      setColorTolerance(initial.rule.colorTolerance || 24);
      setMediaKinds([...initial.rule.mediaKinds]);
      setMinRating(initial.rule.minRating);
    } else {
      setName('');
      setMatchMode('all');
      setSelectedTags([]);
      setCustomTagInput('');
      setDescriptionQuery('');
      setColorHexes([]);
      setColorTolerance(24);
      setMediaKinds([]);
      setMinRating(0);
    }
  }, [open, initial]);

  const pendingTags = useMemo(() => {
    const extra = customTagInput
      .split(/[,，]/)
      .map((t) => t.replace(/^[#＃]+/, '').trim())
      .filter(Boolean);
    if (extra.length === 0) return selectedTags;
    const existingLower = new Set(selectedTags.map((t) => t.toLowerCase()));
    return [...selectedTags, ...extra.filter((t) => !existingLower.has(t.toLowerCase()))];
  }, [selectedTags, customTagInput]);

  const safeColorTolerance = Number.isFinite(colorTolerance)
    ? Math.max(10, Math.min(48, Math.round(colorTolerance)))
    : 24;

  const draftRule = useMemo<SmartFolderRule>(
    () => ({
      matchMode,
      tags: pendingTags,
      descriptionQuery: descriptionQuery.trim(),
      colorHexes,
      colorTolerance: safeColorTolerance,
      mediaKinds,
      minRating,
    }),
    [matchMode, pendingTags, descriptionQuery, colorHexes, safeColorTolerance, mediaKinds, minRating],
  );

  const hasAnyCondition =
    pendingTags.length > 0 ||
    descriptionQuery.trim().length > 0 ||
    colorHexes.length > 0 ||
    mediaKinds.length > 0 ||
    minRating > 0;

  const liveMatchCount = useMemo(
    () => (hasAnyCondition ? getSmartFolderMatchCount(allAssets, draftRule) : 0),
    [allAssets, draftRule, hasAnyCondition],
  );

  const quickTags = useMemo(() => {
    const selectedLower = new Set(selectedTags.map((t) => t.toLowerCase()));
    return getTopTenSidebarTags(availableTags).filter(
      (tc) => !selectedLower.has(tc.name.toLowerCase()),
    );
  }, [availableTags, selectedTags]);

  const addCustomTag = () => {
    const cleaned = customTagInput
      .split(/[,，]/)
      .map((t) => t.replace(/^[#＃]+/, '').trim())
      .filter(Boolean);
    setCustomTagInput('');
    if (cleaned.length === 0) return;
    setSelectedTags((prev) => {
      const existingLower = new Set(prev.map((t) => t.toLowerCase()));
      const additions = cleaned.filter((t) => !existingLower.has(t.toLowerCase()));
      return [...prev, ...additions];
    });
  };

  const toggleColor = (hex: string) => {
    const upper = hex.toUpperCase();
    setColorHexes((prev) =>
      prev.some((c) => c.toUpperCase() === upper)
        ? prev.filter((c) => c.toUpperCase() !== upper)
        : [...prev, upper],
    );
  };

  const toggleKind = (kind: MediaKind) => {
    setMediaKinds((prev) =>
      prev.includes(kind) ? prev.filter((k) => k !== kind) : [...prev, kind],
    );
  };

  const handleSubmit = async (e?: React.FormEvent) => {
    e?.preventDefault();
    if (!hasAnyCondition || saving) return;
    const trimmedName = name.trim() || '智能文件夹';
    const now = msToCocoaSeconds(Date.now());
    const record: SmartFolderRecord = {
      id: initial?.id ?? makeId(),
      name: trimmedName,
      colorHex: colorHexes[0] ?? initial?.colorHex ?? null,
      rule: draftRule,
      sortOrder: initial?.sortOrder ?? smartFoldersCount,
      createdAt: initial?.createdAt ?? now,
      updatedAt: now,
    };
    setSaving(true);
    try {
      await onSave(record);
      onClose();
    } catch (err) {
      pushToast({
        message: `保存智能文件夹失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setSaving(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      title={
        <span className="inline-flex items-center gap-2">
          <CharkleIcon name="smart-folder" style="duotone" size={20} isActive />
          <span>{initial ? '编辑智能文件夹' : '新建智能文件夹'}</span>
        </span>
      }
      subtitle="符合规则的新老素材都会自动实时归入"
      headerRight={
        <span
          className={[
            'px-2.5 py-1 rounded-full text-[11.5px] font-semibold charkle-tabular',
            liveMatchCount > 0
              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
              : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
          ].join(' ')}
        >
          当前匹配 {liveMatchCount} 项
        </span>
      }
      width="md"
      footer={
        <div className="w-full flex items-center justify-between gap-3">
          <span
            className={[
              'text-[12px]',
              hasAnyCondition ? 'text-[var(--text-secondary)]' : 'text-[var(--warning)]',
            ].join(' ')}
          >
            {hasAnyCondition ? '规则就绪' : '请至少设置一个筛选条件'}
          </span>
          <div className="flex items-center gap-2">
            <Button variant="standard" onClick={onClose}>
              取消
            </Button>
            <Button
              variant="accent"
              loading={saving}
              disabled={!hasAnyCondition}
              onClick={() => void handleSubmit()}
            >
              {initial ? '保存规则' : '创建智能文件夹'}
            </Button>
          </div>
        </div>
      }
    >
      <form onSubmit={handleSubmit} className="flex flex-col gap-3.5">
        {/* Name + Match Mode */}
        <div className="flex items-end gap-3 flex-wrap sm:flex-nowrap">
          <div className="flex-1 min-w-[200px] flex flex-col gap-1.5">
            <label
              htmlFor="smart-folder-name-input"
              className="text-[12px] font-medium text-[var(--text-secondary)]"
            >
              文件夹名称
            </label>
            <input
              id="smart-folder-name-input"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="例如：蓝色系夏日插画 / GitHub 灵感"
              autoFocus
              className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
            />
          </div>

          <div className="flex flex-col gap-1.5 shrink-0">
            <span className="text-[12px] font-medium text-[var(--text-secondary)]">
              规则匹配方式
            </span>
            <SegmentedControl<SmartFolderMatchMode>
              value={matchMode}
              onChange={setMatchMode}
              size="xs"
              options={[
                { value: 'all', label: '满足全部' },
                { value: 'any', label: '满足任一' },
              ]}
            />
          </div>
        </div>

        {/* Condition 1: Tags */}
        <div className="p-3 rounded-[var(--win-radius-card)] bg-[var(--win-layer-default)] border border-[var(--win-stroke-card)] flex flex-col gap-2">
          <div className="flex items-baseline gap-1.5">
            <span className="text-[13px] font-semibold text-[var(--text-primary)]">符合标签</span>
            <span className="text-[12px] text-[var(--text-secondary)]">选择已有标签或手动输入</span>
          </div>

          {selectedTags.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {selectedTags.map((tag) => (
                <span
                  key={tag}
                  className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--accent)] text-[var(--accent-text)] text-[12px] font-medium"
                >
                  <span>#{tag}</span>
                  <button
                    type="button"
                    aria-label={`移除标签 ${tag}`}
                    onClick={() => setSelectedTags((prev) => prev.filter((t) => t !== tag))}
                    className="opacity-85 hover:opacity-100 cursor-pointer inline-flex items-center"
                  >
                    <Dismiss12Regular className="w-3 h-3" />
                  </button>
                </span>
              ))}
            </div>
          )}

          <div className="flex items-center gap-2">
            <input
              type="text"
              value={customTagInput}
              onChange={(e) => setCustomTagInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.nativeEvent.isComposing || e.keyCode === 229) return;
                if (e.key === 'Enter') {
                  e.preventDefault();
                  addCustomTag();
                }
              }}
              placeholder="输入标签后回车添加…"
              aria-label="输入标签"
              className="win-input-elevation flex-1 min-w-0 h-8 px-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
            />
            <Button
              type="button"
              variant="standard"
              size="sm"
              disabled={!customTagInput.trim()}
              onClick={addCustomTag}
            >
              添加标签
            </Button>
          </div>

          {quickTags.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {quickTags.map((tc) => (
                <button
                  key={tc.name}
                  type="button"
                  onClick={() => setSelectedTags((prev) => [...prev, tc.name])}
                  className="charkle-pressable win-control-elevation px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  + #{tc.name}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Condition 2: Description / Keywords */}
        <div className="p-3 rounded-[var(--win-radius-card)] bg-[var(--win-layer-default)] border border-[var(--win-stroke-card)] flex flex-col gap-2">
          <div className="flex items-baseline gap-1.5 flex-wrap">
            <span className="text-[13px] font-semibold text-[var(--text-primary)]">
              符合描述 / 关键词
            </span>
            <span className="text-[12px] text-[var(--text-secondary)]">
              匹配标题、AI 描述、备注、OCR 文本、推文正文与 README
            </span>
          </div>
          <input
            type="text"
            value={descriptionQuery}
            onChange={(e) => setDescriptionQuery(e.target.value)}
            placeholder="输入多个关键词用空格分隔，例如：极简 建筑 海报"
            aria-label="描述或关键词"
            className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
        </div>

        {/* Condition 3: Specific Colors */}
        <div className="p-3 rounded-[var(--win-radius-card)] bg-[var(--win-layer-default)] border border-[var(--win-stroke-card)] flex flex-col gap-2.5">
          <div className="flex items-baseline gap-1.5 flex-wrap">
            <span className="text-[13px] font-semibold text-[var(--text-primary)]">特定颜色</span>
            <span className="text-[12px] text-[var(--text-secondary)]">
              匹配任意已选色值的相近主色素材
            </span>
          </div>

          <div className="flex items-center gap-1.5 flex-wrap">
            {QUICK_PALETTE.map((hex) => {
              const active = colorHexes.some((c) => c.toUpperCase() === hex.toUpperCase());
              return (
                <button
                  key={hex}
                  type="button"
                  title={hex}
                  aria-label={`选择颜色 ${hex}`}
                  onClick={() => toggleColor(hex)}
                  style={{ backgroundColor: hex }}
                  className={[
                    'charkle-pressable w-[22px] h-[22px] rounded-full inline-flex items-center justify-center cursor-pointer',
                    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                    active
                      ? 'ring-2 ring-offset-1 ring-[var(--accent)]'
                      : 'border border-black/15',
                  ].join(' ')}
                >
                  {active && (
                    <Checkmark12Regular
                      className={`w-3 h-3 ${isLightHex(hex) ? 'text-black' : 'text-white'}`}
                    />
                  )}
                </button>
              );
            })}

            <span className="flex-1" />

            <input
              type="color"
              aria-label="自定义筛选色"
              value={customColorHex}
              onChange={(e) => setCustomColorHex(e.target.value.toUpperCase())}
              className="w-7 h-7 rounded-[var(--win-radius-control)] border border-[var(--win-stroke-control)] bg-transparent cursor-pointer"
            />
            <Button
              type="button"
              variant="standard"
              size="xs"
              onClick={() => {
                const upper = customColorHex.toUpperCase();
                setColorHexes((prev) =>
                  prev.some((c) => c.toUpperCase() === upper) ? prev : [...prev, upper],
                );
              }}
            >
              加入此色
            </Button>
          </div>

          {colorHexes.length > 0 && (
            <>
              <div className="flex flex-wrap gap-1.5">
                {colorHexes.map((hex) => (
                  <span
                    key={hex}
                    className="win-control-elevation inline-flex items-center gap-1.5 px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] text-[11px] font-medium charkle-mono text-[var(--text-primary)]"
                  >
                    <span
                      className="w-2.5 h-2.5 rounded-full border border-black/15"
                      style={{ backgroundColor: hex }}
                    />
                    <span>{hex}</span>
                    <button
                      type="button"
                      aria-label={`移除颜色 ${hex}`}
                      onClick={() => toggleColor(hex)}
                      className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer inline-flex items-center"
                    >
                      <Dismiss12Regular className="w-2.5 h-2.5" />
                    </button>
                  </span>
                ))}
              </div>

              <div className="flex items-center gap-2.5">
                <span className="text-[12px] text-[var(--text-secondary)]">色彩容差</span>
                <CharkleSlider
                  min={10}
                  max={48}
                  step={2}
                  value={colorTolerance}
                  onChange={setColorTolerance}
                  ariaLabel="色彩容差"
                  variant="standard"
                  size="sm"
                  className="w-[180px]"
                  valueText={`ΔE ≤ ${colorTolerance}`}
                  data-testid="smart-folder-color-tolerance-slider"
                />
                <span className="text-[11.5px] charkle-mono charkle-tabular text-[var(--text-secondary)]">
                  ΔE ≤ {colorTolerance}
                </span>
              </div>
            </>
          )}
        </div>

        {/* Condition 4: Media Kinds */}
        <div className="p-3 rounded-[var(--win-radius-card)] bg-[var(--win-layer-default)] border border-[var(--win-stroke-card)] flex flex-col gap-2">
          <div className="flex items-baseline gap-1.5">
            <span className="text-[13px] font-semibold text-[var(--text-primary)]">素材类型</span>
            <span className="text-[12px] text-[var(--text-secondary)]">不选则不限制类型</span>
          </div>
          <div className="flex flex-wrap gap-1.5">
            {ALL_MEDIA_KINDS.map((kind) => {
              const active = mediaKinds.includes(kind);
              return (
                <button
                  key={kind}
                  type="button"
                  aria-pressed={active}
                  onClick={() => toggleKind(kind)}
                  className={[
                    'charkle-pressable px-2.5 h-7 text-[12px] rounded-[var(--win-radius-control)] cursor-pointer',
                    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                    active
                      ? 'bg-[var(--accent)] text-[var(--accent-text)] font-medium win-accent-elevation'
                      : 'bg-[var(--win-control-fill)] text-[var(--text-primary)] hover:bg-[var(--win-control-fill-hover)] win-control-elevation',
                  ].join(' ')}
                >
                  {mediaKindLabel(kind)}
                </button>
              );
            })}
          </div>
        </div>

        {/* Condition 5: Minimum Rating */}
        <div className="flex items-center gap-2.5 flex-wrap">
          <span className="text-[12px] font-medium text-[var(--text-secondary)]">
            最低星级（可选）
          </span>
          <div className="flex items-center gap-1">
            {[0, 1, 2, 3, 4, 5].map((star) => {
              const active = minRating === star;
              return (
                <button
                  key={star}
                  type="button"
                  aria-pressed={active}
                  onClick={() => setMinRating(star)}
                  className={[
                    'charkle-pressable px-2.5 h-7 rounded-[var(--win-radius-control)] text-[12px] cursor-pointer charkle-tabular',
                    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                    active
                      ? 'bg-[var(--accent)] text-[var(--accent-text)] font-medium win-accent-elevation'
                      : 'bg-[var(--win-control-fill)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-control-fill-hover)] win-control-elevation',
                  ].join(' ')}
                >
                  {star === 0 ? '不限' : `${star}★+`}
                </button>
              );
            })}
          </div>
        </div>
      </form>
    </ModalShell>
  );
};
