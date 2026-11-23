import React, { useEffect, useMemo, useState } from 'react';
import { Plus, Star, X } from 'lucide-react';
import {
  createDefaultSmartFolderRule,
  matchesSmartFolderRule,
  MEDIA_KINDS,
  mediaKindLocalizedLabel,
  smartFolderRuleHasAnyCondition,
} from '@charkle/shared';
import type { MediaKind, SmartFolderRecord, SmartFolderRule } from '@charkle/shared';
import { Button, ModalShell, SMART_FOLDER_PRESET_COLORS } from '../../design-system';
import { useLibraryStore } from '../../stores/libraryStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';

export interface SmartFolderEditorModalProps {
  open: boolean;
  editingFolder: SmartFolderRecord | null;
  onClose: () => void;
}

export const SmartFolderEditorModal: React.FC<SmartFolderEditorModalProps> = ({
  open,
  editingFolder,
  onClose,
}) => {
  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const tags = useLibraryStore((s) => s.tags);
  const saveSmartFolder = useLibraryStore((s) => s.saveSmartFolder);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [name, setName] = useState('');
  const [rule, setRule] = useState<SmartFolderRule>(() => createDefaultSmartFolderRule());
  const [tagInput, setTagInput] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    if (editingFolder) {
      setName(editingFolder.name);
      setRule({ ...editingFolder.rule });
    } else {
      setName('');
      setRule(createDefaultSmartFolderRule());
    }
    setTagInput('');
  }, [open, editingFolder]);

  // Live preview match count across cached assets in store
  const previewAssets = useMemo(() => {
    const known = Object.values(assetsByID);
    return known.length >= assets.length ? known : assets;
  }, [assets, assetsByID]);

  const liveMatchCount = useMemo(() => {
    if (!smartFolderRuleHasAnyCondition(rule)) return 0;
    let count = 0;
    for (const asset of previewAssets) {
      if (matchesSmartFolderRule(rule, asset)) count++;
    }
    return count;
  }, [previewAssets, rule]);

  const addTag = (raw: string) => {
    const cleaned = raw.trim().replace(/^#+/, '');
    if (!cleaned) return;
    if (rule.tags.some((t) => t.toLowerCase() === cleaned.toLowerCase())) return;
    setRule((r) => ({ ...r, tags: [...r.tags, cleaned] }));
    setTagInput('');
  };

  const removeTag = (tag: string) => {
    setRule((r) => ({ ...r, tags: r.tags.filter((t) => t !== tag) }));
  };

  const toggleColor = (hex: string) => {
    const upper = hex.toUpperCase();
    setRule((r) => {
      const exists = r.colorHexes.some((c) => c.toUpperCase() === upper);
      return {
        ...r,
        colorHexes: exists
          ? r.colorHexes.filter((c) => c.toUpperCase() !== upper)
          : [...r.colorHexes, upper],
      };
    });
  };

  const toggleMediaKind = (kind: MediaKind) => {
    setRule((r) => ({
      ...r,
      mediaKinds: r.mediaKinds.includes(kind)
        ? r.mediaKinds.filter((k) => k !== kind)
        : [...r.mediaKinds, kind],
    }));
  };

  const canSave = name.trim().length > 0 && smartFolderRuleHasAnyCondition(rule);

  const handleSave = async () => {
    if (!canSave) return;
    setSaving(true);
    try {
      await saveSmartFolder({
        id: editingFolder?.id,
        name: name.trim(),
        colorHex: rule.colorHexes[0] ?? editingFolder?.colorHex ?? null,
        rule,
        sortOrder: editingFolder?.sortOrder,
      });
      pushToast({
        tone: 'success',
        message: editingFolder ? `已更新智能文件夹「${name.trim()}」` : `已创建智能文件夹「${name.trim()}」`,
      });
      onClose();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存智能文件夹失败',
      });
    } finally {
      setSaving(false);
    }
  };

  const topSuggestedTags = useMemo(() => tags.slice(0, 10), [tags]);

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      width="md"
      title={editingFolder ? '编辑智能文件夹' : '新建智能文件夹'}
      headerRight={
        <span className="px-2.5 py-1 rounded-full text-[11.5px] font-medium bg-[var(--accent-soft)] text-[var(--accent)]">
          当前匹配 {liveMatchCount} 项
        </span>
      }
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            取消
          </Button>
          <Button variant="primary" disabled={!canSave} loading={saving} onClick={handleSave}>
            {editingFolder ? '保存更改' : '创建智能文件夹'}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {/* Name + Match Mode */}
        <div className="grid grid-cols-1 sm:grid-cols-[1fr_auto] gap-3 items-end">
          <div className="flex flex-col gap-1.5">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">名称</label>
            <input
              type="text"
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="例如：暖陶土高分海报 / React 灵感"
              className="h-9 px-3 text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
            />
          </div>
          <div className="flex flex-col gap-1.5">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">匹配逻辑</label>
            <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
              {(['all', 'any'] as const).map((mode) => (
                <button
                  key={mode}
                  type="button"
                  onClick={() => setRule((r) => ({ ...r, matchMode: mode }))}
                  className={[
                    'charkle-pressable px-2.5 py-1 text-[12px] font-medium rounded-[6px] cursor-pointer',
                    rule.matchMode === mode
                      ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                      : 'text-[var(--text-secondary)]',
                  ].join(' ')}
                >
                  {mode === 'all' ? '满足全部' : '满足任一'}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* Tags */}
        <div className="flex flex-col gap-2">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">包含标签</label>
          <div className="flex flex-wrap items-center gap-1.5 p-2 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] min-h-[38px]">
            {rule.tags.map((tag) => (
              <span
                key={tag}
                className="inline-flex items-center gap-1 px-2 py-0.5 text-[12px] rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] font-medium"
              >
                #{tag}
                <button
                  type="button"
                  onClick={() => removeTag(tag)}
                  className="hover:opacity-70 cursor-pointer"
                >
                  <X size={11} />
                </button>
              </span>
            ))}
            <input
              type="text"
              value={tagInput}
              onChange={(e) => setTagInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ',') {
                  e.preventDefault();
                  addTag(tagInput);
                }
              }}
              placeholder="输入标签后回车添加…"
              className="flex-1 min-w-[120px] bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none"
            />
          </div>
          {topSuggestedTags.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {topSuggestedTags.map((t) => {
                const selected = rule.tags.some((x) => x.toLowerCase() === t.name.toLowerCase());
                return (
                  <button
                    key={t.name}
                    type="button"
                    onClick={() => (selected ? removeTag(t.name) : addTag(t.name))}
                    className={[
                      'charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 text-[11.5px] rounded-[var(--radius-chip)] border cursor-pointer',
                      selected
                        ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)]'
                        : 'bg-[var(--bg-subtle)]/70 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    <Plus size={10} />
                    {t.name}
                  </button>
                );
              })}
            </div>
          )}
        </div>

        {/* Keywords */}
        <div className="flex flex-col gap-1.5">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">
            关键词
          </label>
          <input
            type="text"
            value={rule.descriptionQuery}
            onChange={(e) => setRule((r) => ({ ...r, descriptionQuery: e.target.value }))}
            placeholder="空格分隔多个词（全部命中）"
            className="h-9 px-3 text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
          />
        </div>

        {/* Color Matching + Tolerance */}
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">
              色彩匹配
            </label>
            <span className="text-[11.5px] text-[var(--text-tertiary)] font-mono">
              容差 {Math.round(rule.colorTolerance)}
            </span>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {SMART_FOLDER_PRESET_COLORS.map((hex) => {
              const active = rule.colorHexes.some((c) => c.toUpperCase() === hex.toUpperCase());
              return (
                <button
                  key={hex}
                  type="button"
                  title={hex}
                  onClick={() => toggleColor(hex)}
                  className={[
                    'charkle-pressable h-6 w-6 rounded-full border border-black/15 cursor-pointer',
                    active ? 'ring-2 ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-elevated)]' : '',
                  ].join(' ')}
                  style={{ backgroundColor: hex }}
                />
              );
            })}
            <label
              title="添加自定义颜色"
              className="charkle-pressable relative h-6 px-2 inline-flex items-center gap-1 rounded-full text-[11.5px] bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <Plus size={11} />
              自定义
              <input
                type="color"
                onChange={(e) => toggleColor(e.target.value)}
                className="opacity-0 absolute inset-0 w-full h-full cursor-pointer"
              />
            </label>
          </div>
          {rule.colorHexes.length > 0 && (
            <div className="flex items-center gap-3 pt-1">
              <span className="text-[11.5px] text-[var(--text-secondary)] shrink-0">色彩宽容度</span>
              <input
                type="range"
                min={10}
                max={48}
                step={2}
                value={rule.colorTolerance}
                onChange={(e) => setRule((r) => ({ ...r, colorTolerance: Number(e.target.value) }))}
                className="flex-1 accent-[var(--accent)]"
              />
              <button
                type="button"
                onClick={() => setRule((r) => ({ ...r, colorHexes: [] }))}
                className="text-[11.5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                清除颜色
              </button>
            </div>
          )}
        </div>

        {/* Media Kinds */}
        <div className="flex flex-col gap-2">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">媒体类型</label>
          <div className="flex flex-wrap gap-1.5">
            {MEDIA_KINDS.map((kind) => {
              const active = rule.mediaKinds.includes(kind);
              return (
                <button
                  key={kind}
                  type="button"
                  onClick={() => toggleMediaKind(kind)}
                  className={[
                    'charkle-pressable px-2.5 py-1 text-[12px] rounded-[var(--radius-chip)] border cursor-pointer',
                    active
                      ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                      : 'bg-[var(--bg-subtle)]/60 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                  ].join(' ')}
                >
                  {mediaKindLocalizedLabel(kind)}
                </button>
              );
            })}
          </div>
        </div>

        {/* Min Rating */}
        <div className="flex items-center justify-between pt-1">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">最低星级评分</label>
          <div className="flex items-center gap-1">
            {[1, 2, 3, 4, 5].map((star) => {
              const active = rule.minRating >= star;
              return (
                <button
                  key={star}
                  type="button"
                  onClick={() => setRule((r) => ({ ...r, minRating: r.minRating === star ? 0 : star }))}
                  className="charkle-pressable p-1 cursor-pointer"
                >
                  <Star
                    size={17}
                    className={
                      active
                        ? 'fill-[#F2C14E] text-[#F2C14E] charkle-micro-pop'
                        : 'text-[var(--text-tertiary)]'
                    }
                  />
                </button>
              );
            })}
            {rule.minRating > 0 && (
              <span className="text-[11.5px] text-[var(--text-secondary)] ml-1">
                ≥ {rule.minRating} 星
              </span>
            )}
          </div>
        </div>
      </div>
    </ModalShell>
  );
};
