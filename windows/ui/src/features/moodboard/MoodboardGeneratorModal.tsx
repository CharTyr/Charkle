import React, { useMemo, useState } from 'react';
import {
  CheckCircle2,
  CircleDashed,
  Image as ImageIcon,
  Palette,
  Sliders,
  Sparkles,
  Wand2,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  FILTER_PRESET_COLORS,
  ModalShell,
  SegmentedControl,
} from '../../design-system';
import { useLibraryStore, useMoodboardStore } from '../../stores';
import type {
  EditorialStyle,
  LabColor,
  MoodboardCurationRequest,
  MoodboardDocument,
} from '../../types/domain';

type GeneratorEntryTab = 'prompt' | 'seeds' | 'palette' | 'manual' | 'combined';

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

export interface MoodboardGeneratorModalProps {
  open: boolean;
  onClose: () => void;
  existingBoard?: MoodboardDocument | null;
}

/**
 * 4+1 Moodboard Generator Modal + Live 8-Phase Agent Harness Trace (M4-R2).
 */
export const MoodboardGeneratorModal: React.FC<MoodboardGeneratorModalProps> = ({
  open,
  onClose,
  existingBoard = null,
}) => {
  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);

  const curating = useMoodboardStore((s) => s.curating);
  const agentTrace = useMoodboardStore((s) => s.agentTrace);
  const curateMoodboard = useMoodboardStore((s) => s.curateMoodboard);

  const [tab, setTab] = useState<GeneratorEntryTab>('prompt');
  const [prompt, setPrompt] = useState('');
  const [seedAssetIds, setSeedAssetIds] = useState<string[]>([]);
  const [selectedHexes, setSelectedHexes] = useState<string[]>([]);
  const [colorTolerance, setColorTolerance] = useState(28);
  const [scopeFolderIds, setScopeFolderIds] = useState<string[]>([]);
  const [requiredTags, setRequiredTags] = useState<string[]>([]);
  const [preferredCount, setPreferredCount] = useState(12);
  const [layoutStyle, setLayoutStyle] = useState<EditorialStyle>('magazine');
  const [useFreeformLayout, setUseFreeformLayout] = useState(false);
  const [includeCuratorNotes, setIncludeCuratorNotes] = useState(true);
  const [autoFocusDetailCrop, setAutoFocusDetailCrop] = useState(false);

  const transport = getTransport();
  const pickableAssets = useMemo(() => assets.filter((a) => !a.isTrashed).slice(0, 36), [assets]);

  const toggleItem = (list: string[], id: string, setter: (v: string[]) => void) => {
    setter(list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
  };

  const handleGenerate = async () => {
    const req: MoodboardCurationRequest = {
      prompt: tab === 'palette' || tab === 'manual' ? '' : prompt.trim(),
      seedAssetIDs: tab === 'prompt' || tab === 'palette' ? [] : seedAssetIds,
      scopeFolderIDs: scopeFolderIds,
      requiredTags,
      targetPalette:
        tab === 'palette' || tab === 'combined' ? selectedHexes.map(hexToApproxLab) : [],
      colorTolerance,
      preferredCount: tab === 'manual' && seedAssetIds.length > 0 ? seedAssetIds.length : preferredCount,
      candidateCount: 28,
      layoutStyle,
      useFreeformLayout,
      includeCuratorNotes,
      excludedAssetIDs: [],
      lockedAssetIDs: tab === 'manual' ? seedAssetIds : [],
      existingBoard,
      refinementInstruction: null,
      autoFocusDetailCrop,
    };
    await curateMoodboard(req);
    onClose();
  };

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      title={existingBoard ? '智能重排与补充策展' : '10 秒智能生成情绪板'}
      subtitle="4+1 入口驱动：主题词、种子图、主色板、手选或综合策展，同步生成 20–40 项候选替换池"
      width="lg"
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>
            取消
          </Button>
          <Button variant="primary" loading={curating} onClick={() => void handleGenerate()}>
            <Sparkles size={14} />
            立即生成情绪板
          </Button>
        </>
      }
    >
      <div data-testid="moodboard-generator-modal" className="flex flex-col gap-4">
        {/* 4+1 Entry Switcher */}
        <SegmentedControl<GeneratorEntryTab>
          value={tab}
          onChange={setTab}
          ariaLabel="生成入口模式"
          options={[
            { value: 'prompt', label: '灵感主题词', icon: <Wand2 size={12.5} /> },
            { value: 'seeds', label: '种子参考图', icon: <ImageIcon size={12.5} /> },
            { value: 'palette', label: '色板驱动', icon: <Palette size={12.5} /> },
            { value: 'manual', label: '手动挑选' },
            { value: 'combined', label: '综合策展', icon: <Sliders size={12.5} /> },
          ]}
        />

        {/* Prompt Input */}
        {(tab === 'prompt' || tab === 'combined') && (
          <div className="flex flex-col gap-1.5">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">
              描述视觉方向、材质质感或氛围关键词
            </label>
            <input
              type="text"
              value={prompt}
              autoFocus
              onChange={(e) => setPrompt(e.target.value)}
              placeholder="例如：暖石膏建筑、低角度晨光阴影、瑞士极简杂志排版…"
              className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </div>
        )}

        {/* Seed / Manual Asset Picker */}
        {(tab === 'seeds' || tab === 'manual' || tab === 'combined') && (
          <div className="flex flex-col gap-1.5">
            <div className="flex items-center justify-between text-[12px]">
              <span className="font-medium text-[var(--text-secondary)]">
                {tab === 'manual' ? '勾选要放入情绪板的素材' : '选择 1–6 张种子参考素材'}
              </span>
              <span className="text-[var(--text-tertiary)] charkle-tabular">
                已选 {seedAssetIds.length} 项
              </span>
            </div>
            <div className="grid grid-cols-6 gap-1.5 max-h-[168px] overflow-y-auto charkle-scroll p-1 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/60">
              {pickableAssets.map((a) => {
                const selected = seedAssetIds.includes(a.id);
                return (
                  <button
                    key={a.id}
                    type="button"
                    title={a.title}
                    onClick={() => toggleItem(seedAssetIds, a.id, setSeedAssetIds)}
                    className={[
                      'relative aspect-square rounded-[var(--radius-card-inner)] overflow-hidden cursor-pointer',
                      selected ? 'ring-2 ring-[var(--accent)]' : 'opacity-80 hover:opacity-100',
                    ].join(' ')}
                  >
                    <img
                      src={transport.thumbnailUrl(a.id, 'grid520')}
                      alt={a.title}
                      className="w-full h-full object-cover"
                    />
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {/* Color Palette Picker + ΔE Tolerance */}
        {(tab === 'palette' || tab === 'combined') && (
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between text-[12px]">
              <span className="font-medium text-[var(--text-secondary)]">目标主色板</span>
              <span className="text-[11.5px] text-[var(--text-tertiary)] charkle-tabular">
                色差容忍 {colorTolerance}
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
                    onClick={() => toggleItem(selectedHexes, hex, setSelectedHexes)}
                    className={[
                      'charkle-pressable h-7 w-7 rounded-full border border-black/15 cursor-pointer',
                      active ? 'ring-2 ring-offset-2 ring-[var(--accent)]' : '',
                    ].join(' ')}
                    style={{ backgroundColor: hex }}
                  />
                );
              })}
            </div>
            <input
              type="range"
              min={10}
              max={55}
              value={colorTolerance}
              onChange={(e) => setColorTolerance(Number(e.target.value))}
              className="w-full accent-[var(--accent)]"
            />
          </div>
        )}

        {/* Folder & Tag Scope */}
        {(folders.length > 0 || tagCounts.length > 0) && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-1 border-t border-[var(--border-hairline)]">
            {folders.length > 0 && (
              <div className="flex flex-col gap-1.5">
                <span className="text-[11.5px] font-medium text-[var(--text-tertiary)]">
                  限定检索文件夹（留空为全库）
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
                          'charkle-pressable h-6 px-2 rounded-full text-[11.5px] cursor-pointer',
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
                          'charkle-pressable h-6 px-2 rounded-full text-[11.5px] cursor-pointer',
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

        {/* Layout Style, Mode & Count Options */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-2 border-t border-[var(--border-hairline)]">
          <div className="flex flex-col gap-1.5">
            <span className="text-[11.5px] font-medium text-[var(--text-tertiary)]">编排风格</span>
            <SegmentedControl<EditorialStyle>
              value={layoutStyle}
              onChange={setLayoutStyle}
              options={[
                { value: 'magazine', label: '杂志 Hero' },
                { value: 'balanced', label: '均衡 Bento' },
                { value: 'compact', label: '高密拼贴' },
              ]}
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <div className="flex items-center justify-between text-[11.5px]">
              <span className="font-medium text-[var(--text-tertiary)]">主画布张数</span>
              <span className="charkle-tabular text-[var(--text-secondary)]">{preferredCount} 张</span>
            </div>
            <input
              type="range"
              min={4}
              max={24}
              value={preferredCount}
              onChange={(e) => setPreferredCount(Number(e.target.value))}
              className="w-full accent-[var(--accent)]"
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
            直接进入自由拼贴画布
          </label>
          <label className="inline-flex items-center gap-1.5 cursor-pointer">
            <input
              type="checkbox"
              checked={includeCuratorNotes}
              onChange={(e) => setIncludeCuratorNotes(e.target.checked)}
              className="accent-[var(--accent)]"
            />
            附带策展思路便签
          </label>
          <label className="inline-flex items-center gap-1.5 cursor-pointer">
            <input
              type="checkbox"
              checked={autoFocusDetailCrop}
              onChange={(e) => setAutoFocusDetailCrop(e.target.checked)}
              className="accent-[var(--accent)]"
            />
            自动细节聚焦裁切
          </label>
        </div>

        {/* Live 8-Phase Agent Harness Trace */}
        {agentTrace.length > 0 && (
          <div
            data-testid="agent-harness-trace"
            className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] flex flex-col gap-1.5"
          >
            <div className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
              策展引擎执行轨迹
            </div>
            {agentTrace.map((step) => (
              <div key={step.id} className="flex items-start gap-2 text-[11.5px]">
                {step.status === 'done' ? (
                  <CheckCircle2 size={13.5} className="text-[var(--success)] shrink-0 mt-0.5" />
                ) : (
                  <CircleDashed size={13.5} className="text-[var(--accent)] shrink-0 mt-0.5 animate-spin" />
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
