import React, { useState } from 'react';
import {
  AlertTriangle,
  Check,
  Copy,
  Download,
  FileArchive,
  Image as ImageIcon,
  Layers,
} from 'lucide-react';
import type {
  FigmaBridgeReport,
  MoodboardDocument,
  MoodboardExportFormat,
  MoodboardExportOptions,
} from '@charkle/shared';
import { apiClient } from '../../api/client';
import { Button } from '../../design-system/Button';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';

export interface ExportBoardModalProps {
  open: boolean;
  onClose: () => void;
  document: MoodboardDocument;
  containerWidth?: number;
}

type ExportTab = 'image' | 'figma';

function triggerDownloadBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = window.document.createElement('a');
  a.href = url;
  a.download = filename;
  window.document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export const ExportBoardModal: React.FC<ExportBoardModalProps> = ({
  open,
  onClose,
  document,
  containerWidth = 1280,
}) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [tab, setTab] = useState<ExportTab>('image');
  const [format, setFormat] = useState<MoodboardExportFormat>('png');
  const [scale, setScale] = useState<1 | 2>(2);
  const [includeAnnotations, setIncludeAnnotations] = useState(true);
  const [includePaletteStrip, setIncludePaletteStrip] = useState(true);
  const [darkAppearance, setDarkAppearance] = useState(false);

  const [busyAction, setBusyAction] = useState<'download-img' | 'copy-img' | 'figma' | null>(null);
  const [copiedImage, setCopiedImage] = useState(false);
  const [figmaReport, setFigmaReport] = useState<FigmaBridgeReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  const options: MoodboardExportOptions = {
    scale,
    includeAnnotations,
    includePaletteStrip,
    darkAppearance,
    padding: 40,
  };

  const safeSlug = (document.title || 'moodboard')
    .replace(/[/\\:*?"<>|]/g, '-')
    .trim()
    .slice(0, 64);

  const handleDownloadImage = async () => {
    setBusyAction('download-img');
    setError(null);
    try {
      const blob = await apiClient.exportBoardImage(document.id, {
        format,
        containerWidth,
        options,
      });
      triggerDownloadBlob(blob, `${safeSlug}-${scale}x.${format === 'jpeg' ? 'jpg' : 'png'}`);
      pushToast({ tone: 'success', message: `已导出 ${scale}× 高清 ${format.toUpperCase()} 图像` });
    } catch (err) {
      setError(err instanceof Error ? err.message : '导出高清图像失败');
    } finally {
      setBusyAction(null);
    }
  };

  const handleCopyImage = async () => {
    setBusyAction('copy-img');
    setError(null);
    try {
      const blob = await apiClient.exportBoardImage(document.id, {
        format: 'png',
        containerWidth,
        options,
      });
      if (typeof ClipboardItem === 'undefined' || !navigator.clipboard?.write) {
        triggerDownloadBlob(blob, `${safeSlug}-${scale}x.png`);
        pushToast({
          tone: 'info',
          message: '当前浏览器不支持直接写入剪贴板图像，已改为下载 PNG',
        });
      } else {
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
        setCopiedImage(true);
        window.setTimeout(() => setCopiedImage(false), 1800);
        pushToast({ tone: 'success', message: '高清 PNG 已复制到剪贴板' });
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : '复制图像失败');
    } finally {
      setBusyAction(null);
    }
  };

  const handleExportFigma = async () => {
    setBusyAction('figma');
    setError(null);
    try {
      const result = await apiClient.exportBoardFigma(document.id, options);
      triggerDownloadBlob(result.blob, result.filename || `${safeSlug}.charkleboard`);
      if (result.report) {
        setFigmaReport(result.report);
      } else {
        // Synthesize accurate preview summary if server header omitted
        const imgCount = document.nodes.filter((n) => n.kind.type === 'assetRef').length;
        const noteCount = document.nodes.filter((n) => n.kind.type === 'note').length;
        const groupCount = document.nodes.filter((n) => n.kind.type === 'groupFrame').length;
        const paletteCount =
          document.nodes.filter((n) => n.kind.type === 'paletteStrip').length +
          (includePaletteStrip && document.extractedPalette.length > 0 ? 1 : 0);
        setFigmaReport({
          objectCount: document.nodes.length,
          imageCount: imgCount,
          noteCount,
          groupCount,
          paletteCount,
          connectorCount: includeAnnotations ? document.connectors.length : 0,
          strokeCount: includeAnnotations ? document.inkStrokes.length : 0,
          reviewCount: 0,
          warnings: [],
        });
      }
      pushToast({ tone: 'success', message: '已生成无损 .charkleboard 迁移包' });
    } catch (err) {
      setError(err instanceof Error ? err.message : '生成 Figma 迁移包失败');
    } finally {
      setBusyAction(null);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      width="lg"
      title={
        <span className="inline-flex items-center gap-2">
          <CharkleIcon name="export" size={18} />
          导出与交付情绪板
        </span>
      }
      subtitle={`「${document.title}」 · ${document.nodes.length} 个画布元素`}
    >
      <div className="flex flex-col gap-5">
        {/* 2-Tab Segmented Switcher */}
        <div
          className="relative grid grid-cols-2 p-1 rounded-[var(--radius-settings-outer)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]"
          role="tablist"
        >
          <span
            aria-hidden="true"
            className="absolute top-1 bottom-1 left-1 w-[calc(50%-4px)] rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] shadow-xs transition-transform duration-[240ms]"
            style={{
              transitionTimingFunction: 'var(--ease-in-out)',
              transform: tab === 'image' ? 'translateX(0)' : 'translateX(100%)',
            }}
          />
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'image'}
            onClick={() => setTab('image')}
            className={[
              'relative z-10 inline-flex items-center justify-center gap-2 py-2 text-[13px] font-medium cursor-pointer',
              tab === 'image' ? 'text-[var(--text-primary)]' : 'text-[var(--text-secondary)]',
            ].join(' ')}
          >
            <ImageIcon size={15} />
            高清图片 (PNG / JPG)
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'figma'}
            onClick={() => setTab('figma')}
            className={[
              'relative z-10 inline-flex items-center justify-center gap-2 py-2 text-[13px] font-medium cursor-pointer',
              tab === 'figma' ? 'text-[var(--text-primary)]' : 'text-[var(--text-secondary)]',
            ].join(' ')}
          >
            <Layers size={15} />
            Figma / FigJam 无损桥接 (.charkleboard)
          </button>
        </div>

        {error && (
          <div className="px-3.5 py-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[var(--danger)] text-[12.5px] flex items-center gap-2">
            <AlertTriangle size={15} className="shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {/* Shared Rendering Options */}
        <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3.5">
          {tab === 'image' && (
            <>
              <div className="flex items-center justify-between gap-4">
                <div>
                  <div className="text-[13px] font-medium text-[var(--text-primary)]">输出格式</div>
                  <div className="text-[11.5px] text-[var(--text-secondary)]">
                    PNG 保留无损清晰度，JPG 体积更小便于即时分享
                  </div>
                </div>
                <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
                  {(['png', 'jpeg'] as const).map((fmt) => (
                    <button
                      key={fmt}
                      type="button"
                      onClick={() => setFormat(fmt)}
                      className={[
                        'px-3 py-1 rounded-[6px] text-[12px] font-medium uppercase cursor-pointer',
                        format === fmt
                          ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                          : 'text-[var(--text-secondary)]',
                      ].join(' ')}
                    >
                      {fmt === 'jpeg' ? 'JPG' : 'PNG'}
                    </button>
                  ))}
                </div>
              </div>

              <div className="border-t border-[var(--border-hairline)]" />

              <div className="flex items-center justify-between gap-4">
                <div>
                  <div className="text-[13px] font-medium text-[var(--text-primary)]">分辨率倍率</div>
                  <div className="text-[11.5px] text-[var(--text-secondary)]">
                    推荐使用 2× Retina 高清倍率，放大审稿不模糊
                  </div>
                </div>
                <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
                  {([1, 2] as const).map((s) => (
                    <button
                      key={s}
                      type="button"
                      onClick={() => setScale(s)}
                      className={[
                        'px-3 py-1 rounded-[6px] text-[12px] font-medium cursor-pointer tabular-nums',
                        scale === s
                          ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                          : 'text-[var(--text-secondary)]',
                      ].join(' ')}
                    >
                      {s}× {s === 2 ? '高清' : '标准'}
                    </button>
                  ))}
                </div>
              </div>

              <div className="border-t border-[var(--border-hairline)]" />
            </>
          )}

          {/* Annotations & Palette toggles */}
          <div className="flex flex-wrap items-center justify-between gap-3">
            <label className="inline-flex items-center gap-2 text-[12.5px] text-[var(--text-primary)] cursor-pointer">
              <input
                type="checkbox"
                checked={includeAnnotations}
                onChange={(e) => setIncludeAnnotations(e.target.checked)}
                className="accent-[var(--accent)] rounded"
              />
              包含连线箭头与手绘标注
            </label>

            <label className="inline-flex items-center gap-2 text-[12.5px] text-[var(--text-primary)] cursor-pointer">
              <input
                type="checkbox"
                checked={includePaletteStrip}
                onChange={(e) => setIncludePaletteStrip(e.target.checked)}
                className="accent-[var(--accent)] rounded"
              />
              包含顶部板内色卡条
            </label>

            <label className="inline-flex items-center gap-2 text-[12.5px] text-[var(--text-primary)] cursor-pointer">
              <input
                type="checkbox"
                checked={darkAppearance}
                onChange={(e) => setDarkAppearance(e.target.checked)}
                className="accent-[var(--accent)] rounded"
              />
              深色画布背景
            </label>
          </div>
        </div>

        {tab === 'image' ? (
          <div className="flex items-center justify-end gap-2.5">
            <Button
              variant="secondary"
              size="md"
              loading={busyAction === 'copy-img'}
              onClick={handleCopyImage}
            >
              {copiedImage ? <Check size={15} /> : <Copy size={15} />}
              {copiedImage ? '已复制图片' : '复制 PNG 到剪贴板'}
            </Button>
            <Button
              variant="primary"
              size="md"
              loading={busyAction === 'download-img'}
              onClick={handleDownloadImage}
            >
              <Download size={15} />
              下载 {scale}× {format === 'jpeg' ? 'JPG' : 'PNG'}
            </Button>
          </div>
        ) : (
          <div className="flex flex-col gap-4">
            {/* Offline lossless explanation + CTA */}
            <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
              <div className="flex items-start gap-3">
                <div className="w-10 h-10 rounded-[10px] bg-[var(--bg-subtle)] flex items-center justify-center shrink-0">
                  <FileArchive size={20} className="text-[var(--accent)]" />
                </div>
                <div>
                  <div className="text-[13.5px] font-semibold text-[var(--text-primary)]">
                    离线无损 `.charkleboard` 迁移包 (Bridge v1)
                  </div>
                  <p className="text-[12px] text-[var(--text-secondary)] mt-0.5 leading-relaxed">
                    完整保留独立图层、4096px 无损 PNG 切片（含 SHA-256 校验）、原始动态 GIF、可编辑便签、分组框、箭头连线与手绘笔迹，100% 离线导入 Figma / FigJam。
                  </p>
                </div>
              </div>
              <Button
                variant="primary"
                size="md"
                loading={busyAction === 'figma'}
                onClick={handleExportFigma}
                className="shrink-0"
              >
                <Download size={15} />
                下载 .charkleboard
              </Button>
            </div>

            {/* Summary Report (shown after export) */}
            {figmaReport && (
              <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] p-4">
                <div className="text-[12px] font-semibold text-[var(--text-primary)] mb-2.5 flex items-center gap-1.5">
                  <Check size={14} className="text-[var(--success)]" />
                  导出摘要报告
                </div>
                <div className="grid grid-cols-3 sm:grid-cols-6 gap-2 text-center">
                  {[
                    { label: '总对象', value: figmaReport.objectCount },
                    { label: '图像图层', value: figmaReport.imageCount },
                    { label: '便签', value: figmaReport.noteCount },
                    { label: '分组框', value: figmaReport.groupCount },
                    { label: '连线', value: figmaReport.connectorCount },
                    { label: '笔迹', value: figmaReport.strokeCount },
                  ].map((stat) => (
                    <div
                      key={stat.label}
                      className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] py-2 px-1"
                    >
                      <div className="text-[15px] font-semibold text-[var(--text-primary)] tabular-nums">
                        {stat.value}
                      </div>
                      <div className="text-[10.5px] text-[var(--text-secondary)]">{stat.label}</div>
                    </div>
                  ))}
                </div>
                {figmaReport.warnings.length > 0 && (
                  <div className="mt-3 pt-2.5 border-t border-[var(--border-hairline)] text-[11.5px] text-[var(--warning)] space-y-1">
                    {figmaReport.warnings.map((w) => (
                      <div key={w.id}>
                        • {w.name}：{w.issues.join('；')}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* 3-Step Figma Plugin Guide */}
            <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] p-4">
              <div className="text-[12.5px] font-semibold text-[var(--text-primary)] mb-3">
                3 步导入 Figma / FigJam（随仓库内置插件 <code className="font-mono text-[11.5px] px-1.5 py-0.5 rounded bg-[var(--bg-subtle)]">figma-plugin/</code>）
              </div>
              <ol className="space-y-2.5 text-[12px] text-[var(--text-secondary)]">
                <li className="flex items-start gap-2.5">
                  <span className="w-5 h-5 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11px] font-semibold text-[var(--text-primary)] inline-flex items-center justify-center shrink-0 mt-0.5">
                    1
                  </span>
                  <span>
                    在 Figma 桌面端打开菜单{' '}
                    <strong className="text-[var(--text-primary)]">
                      Plugins → Development → Import plugin from manifest…
                    </strong>
                    ，选择本项目根目录下的{' '}
                    <code className="font-mono text-[11.5px] px-1 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-primary)]">
                      figma-plugin/manifest.json
                    </code>
                    。
                  </span>
                </li>
                <li className="flex items-start gap-2.5">
                  <span className="w-5 h-5 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11px] font-semibold text-[var(--text-primary)] inline-flex items-center justify-center shrink-0 mt-0.5">
                    2
                  </span>
                  <span>
                    在任意 Figma 设计文件或 FigJam 白板中运行{' '}
                    <strong className="text-[var(--text-primary)]">Charkle Board Importer</strong>{' '}
                    插件。
                  </span>
                </li>
                <li className="flex items-start gap-2.5">
                  <span className="w-5 h-5 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11px] font-semibold text-[var(--text-primary)] inline-flex items-center justify-center shrink-0 mt-0.5">
                    3
                  </span>
                  <span>
                    将刚下载的 <code className="font-mono text-[11.5px]">.charkleboard</code>{' '}
                    拖入插件窗口即可 1:1 还原全部可编辑图层与动图。
                  </span>
                </li>
              </ol>
            </div>
          </div>
        )}
      </div>
    </ModalShell>
  );
};
