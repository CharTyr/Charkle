import React, { useEffect, useState } from 'react';
import { Star } from 'lucide-react';
import {
  Button,
  FILTER_PRESET_COLORS,
  ModalShell,
  SMART_FOLDER_PRESET_COLORS,
  SegmentedControl,
} from '../../design-system';
import {
  mediaKindLabel,
  msToCocoaSeconds,
  type MediaKind,
  type SmartFolderMatchMode,
  type SmartFolderRecord,
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

export const SmartFolderEditorModal: React.FC<SmartFolderEditorModalProps> = ({
  open,
  onClose,
  initial,
  availableTags,
  onSave,
}) => {
  const [name, setName] = useState('');
  const [colorHex, setColorHex] = useState<string>('#2A60E0');
  const [matchMode, setMatchMode] = useState<SmartFolderMatchMode>('all');
  const [tagsText, setTagsText] = useState('');
  const [descriptionQuery, setDescriptionQuery] = useState('');
  const [colorHexes, setColorHexes] = useState<string[]>([]);
  const [colorTolerance, setColorTolerance] = useState(24);
  const [mediaKinds, setMediaKinds] = useState<MediaKind[]>([]);
  const [minRating, setMinRating] = useState(0);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    if (initial) {
      setName(initial.name);
      setColorHex(initial.colorHex ?? '#2A60E0');
      setMatchMode(initial.rule.matchMode);
      setTagsText(initial.rule.tags.join(', '));
      setDescriptionQuery(initial.rule.descriptionQuery);
      setColorHexes(initial.rule.colorHexes);
      setColorTolerance(initial.rule.colorTolerance || 24);
      setMediaKinds(initial.rule.mediaKinds);
      setMinRating(initial.rule.minRating);
    } else {
      setName('');
      setColorHex('#2A60E0');
      setMatchMode('all');
      setTagsText('');
      setDescriptionQuery('');
      setColorHexes([]);
      setColorTolerance(24);
      setMediaKinds([]);
      setMinRating(0);
    }
  }, [open, initial]);

  const toggleKind = (kind: MediaKind) => {
    setMediaKinds((prev) =>
      prev.includes(kind) ? prev.filter((k) => k !== kind) : [...prev, kind],
    );
  };

  const toggleColor = (hex: string) => {
    setColorHexes((prev) =>
      prev.includes(hex) ? prev.filter((c) => c !== hex) : [...prev, hex],
    );
  };

  const appendTag = (tag: string) => {
    const existing = tagsText
      .split(/[,，]/)
      .map((t) => t.trim())
      .filter(Boolean);
    if (!existing.includes(tag)) {
      setTagsText([...existing, tag].join(', '));
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmedName = name.trim() || '未命名智能文件夹';
    const tags = tagsText
      .split(/[,，]/)
      .map((t) => t.trim())
      .filter(Boolean);
    const now = msToCocoaSeconds(Date.now());
    const record: SmartFolderRecord = {
      id: initial?.id ?? makeId(),
      name: trimmedName,
      colorHex,
      rule: {
        matchMode,
        tags,
        descriptionQuery: descriptionQuery.trim(),
        colorHexes,
        colorTolerance,
        mediaKinds,
        minRating,
      },
      sortOrder: initial?.sortOrder ?? 0,
      createdAt: initial?.createdAt ?? now,
      updatedAt: now,
    };
    setSaving(true);
    try {
      await onSave(record);
      onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      title={initial ? '编辑智能文件夹' : '新建智能文件夹'}
      subtitle="按规则自动动态汇集符合条件的素材"
      width="md"
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>
            取消
          </Button>
          <Button variant="primary" loading={saving} onClick={handleSubmit}>
            保存规则
          </Button>
        </>
      }
    >
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        {/* Name & Color */}
        <div className="flex flex-col gap-2">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">名称</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="例如：高分建筑参考、暖色排版…"
            autoFocus
            className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
          <div className="flex items-center gap-1.5 pt-1 flex-wrap">
            {SMART_FOLDER_PRESET_COLORS.map((hex) => (
              <button
                key={hex}
                type="button"
                onClick={() => setColorHex(hex)}
                className={[
                  'charkle-pressable h-5 w-5 rounded-full border border-black/10 cursor-pointer',
                  colorHex === hex ? 'ring-2 ring-offset-1 ring-[var(--accent)]' : '',
                ].join(' ')}
                style={{ backgroundColor: hex }}
                aria-label={`选择颜色 ${hex}`}
              />
            ))}
          </div>
        </div>

        {/* Match mode */}
        <div className="flex items-center justify-between">
          <span className="text-[12px] font-medium text-[var(--text-secondary)]">规则匹配方式</span>
          <SegmentedControl<SmartFolderMatchMode>
            value={matchMode}
            onChange={setMatchMode}
            options={[
              { value: 'all', label: '满足全部条件' },
              { value: 'any', label: '满足任一条件' },
            ]}
          />
        </div>

        {/* Media kinds */}
        <div className="flex flex-col gap-1.5">
          <span className="text-[12px] font-medium text-[var(--text-secondary)]">媒体类型</span>
          <div className="flex flex-wrap gap-1.5">
            {ALL_MEDIA_KINDS.map((kind) => {
              const active = mediaKinds.includes(kind);
              return (
                <button
                  key={kind}
                  type="button"
                  onClick={() => toggleKind(kind)}
                  className={[
                    'charkle-pressable h-7 px-2.5 text-[12px] rounded-[var(--radius-chip)] border cursor-pointer',
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

        {/* Rating */}
        <div className="flex items-center justify-between">
          <span className="text-[12px] font-medium text-[var(--text-secondary)]">最低评分</span>
          <div className="flex items-center gap-1">
            {[0, 1, 2, 3, 4, 5].map((star) => (
              <button
                key={star}
                type="button"
                onClick={() => setMinRating(star)}
                className={[
                  'charkle-pressable h-7 px-2 inline-flex items-center gap-0.5 rounded-[var(--radius-chip)] text-[12px] cursor-pointer',
                  minRating === star
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                    : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
                ].join(' ')}
              >
                {star === 0 ? (
                  '不限'
                ) : (
                  <>
                    <Star size={11.5} className="fill-current" />
                    <span className="charkle-tabular">{star}+</span>
                  </>
                )}
              </button>
            ))}
          </div>
        </div>

        {/* Tags */}
        <div className="flex flex-col gap-1.5">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">
            包含标签（以逗号分隔）
          </label>
          <input
            type="text"
            value={tagsText}
            onChange={(e) => setTagsText(e.target.value)}
            placeholder="海报, 排版, 建筑…"
            className="h-8 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
          {availableTags.length > 0 && (
            <div className="flex flex-wrap gap-1 pt-0.5">
              {availableTags.slice(0, 10).map((tag) => (
                <button
                  key={tag.name}
                  type="button"
                  onClick={() => appendTag(tag.name)}
                  className="charkle-pressable px-2 py-0.5 text-[11px] rounded-full bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  + {tag.name}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Description / keyword */}
        <div className="flex flex-col gap-1.5">
          <label className="text-[12px] font-medium text-[var(--text-secondary)]">
            标题 / 备注关键词
          </label>
          <input
            type="text"
            value={descriptionQuery}
            onChange={(e) => setDescriptionQuery(e.target.value)}
            placeholder="输入要匹配的关键词…"
            className="h-8 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
        </div>

        {/* Colors */}
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <span className="text-[12px] font-medium text-[var(--text-secondary)]">主色筛选</span>
            {colorHexes.length > 0 && (
              <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular">
                容差 {colorTolerance}
              </span>
            )}
          </div>
          <div className="flex items-center gap-1.5 flex-wrap">
            {FILTER_PRESET_COLORS.map((hex) => {
              const selected = colorHexes.includes(hex);
              return (
                <button
                  key={hex}
                  type="button"
                  onClick={() => toggleColor(hex)}
                  className={[
                    'charkle-pressable h-6 w-6 rounded-full border border-black/15 cursor-pointer',
                    selected ? 'ring-2 ring-offset-1 ring-[var(--accent)]' : '',
                  ].join(' ')}
                  style={{ backgroundColor: hex }}
                  aria-label={`筛色 ${hex}`}
                />
              );
            })}
          </div>
          {colorHexes.length > 0 && (
            <input
              type="range"
              min={10}
              max={50}
              value={colorTolerance}
              onChange={(e) => setColorTolerance(Number(e.target.value))}
              className="w-full accent-[var(--accent)]"
            />
          )}
        </div>
      </form>
    </ModalShell>
  );
};
