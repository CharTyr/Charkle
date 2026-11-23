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
import type {
  ExportBackgroundMode,
  ExportProgressInfo,
} from '../../lib/client-board-export';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useSyncAIStore } from '../../stores/syncAIStore';

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
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const runtimeMode = useSyncAIStore((s) => s.runtimeMode);
  const runtimeFeatures = useSyncAIStore((s) => s.runtimeFeatures);

  const [tab, setTab] = useState<ExportTab>('image');
  const [format, setFormat] = useState<MoodboardExportFormat>('png');
  const [scale, setScale] = useState<1 | 2>(2);
  const [includeAnnotations, setIncludeAnnotations] = useState(true);
  const [includePaletteStrip, setIncludePaletteStrip] = useState(true);
  const [backgroundMode, setBackgroundMode] = useState<ExportBackgroundMode>('light');

  const [busyAction, setBusyAction] = useState<'download-img' | 'copy-img' | 'figma' | null>(null);
  const [exportProgress, setExportProgress] = useState<ExportProgressInfo | null>(null);
  const [copiedImage, setCopiedImage] = useState(false);
  const [figmaReport, setFigmaReport] = useState<FigmaBridgeReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  const preferClientExport =
    runtimeMode === 'cloudflare' || runtimeFeatures.clientExportPreferred;
  const darkAppearance = backgroundMode === 'dark';
  const effectiveImageBackground: ExportBackgroundMode =
    format === 'jpeg' && backgroundMode === 'transparent' ? 'light' : backgroundMode;

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

  const produceImageBlob = async (
    targetFormat: MoodboardExportFormat,
    bgMode: ExportBackgroundMode,
  ): Promise<{ blob: Blob; filename: string }> => {
    const useBrowser = preferClientExport || bgMode === 'transparent';
    if (useBrowser) {
      const { exportMoodboardImageInBrowser } = await import('../../lib/client-board-export');
      const res = await exportMoodboardImageInBrowser({
        document,
        assetsByID,
        format: targetFormat,
        backgroundMode: bgMode,
        containerWidth,
        options,
        onProgress: setExportProgress,
      });
      return { blob: res.blob, filename: res.filename };
    }

    try {
      const blob = await apiClient.exportBoardImage(document.id, {
        format: targetFormat,
        containerWidth,
        options,
      });
      return {
        blob,
        filename: `${safeSlug}-${scale}x.${targetFormat === 'jpeg' ? 'jpg' : 'png'}`,
      };
    } catch {
      const { exportMoodboardImageInBrowser } = await import('../../lib/client-board-export');
      const res = await exportMoodboardImageInBrowser({
        document,
        assetsByID,
        format: targetFormat,
        backgroundMode: bgMode,
        containerWidth,
        options,
        onProgress: setExportProgress,
      });
      return { blob: res.blob, filename: res.filename };
    }
  };

  const handleDownloadImage = async () => {
    setBusyAction('download-img');
    setExportProgress(null);
    setError(null);
    try {
      const { blob, filename } = await produceImageBlob(format, effectiveImageBackground);
      triggerDownloadBlob(blob, filename);
      pushToast({ tone: 'success', message: `已导出 ${scale}× 高清 ${format.toUpperCase()} 图像` });
    } catch (err) {
      setError(err instanceof Error ? err.message : '导出高清图像失败');
    } finally {
      setBusyAction(null);
      setExportProgress(null);
    }
  };

  const handleCopyImage = async () => {
    setBusyAction('copy-img');
    setExportProgress(null);
    setError(null);
    try {
      const { blob, filename } = await produceImageBlob('png', backgroundMode);
      if (typeof ClipboardItem === 'undefined' || !navigator.clipboard?.write) {
        triggerDownloadBlob(blob, filename);
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
      setExportProgress(null);
    }
  };

  const handleExportFigma = async () => {
    setBusyAction('figma');
    setExportProgress(null);
    setError(null);
    try {
      let result: { blob: Blob; filename: string; report?: FigmaBridgeReport };
      if (preferClientExport) {
        const { exportFigmaBridgeInBrowser } = await import('../../lib/client-board-export');
        result = await exportFigmaBridgeInBrowser({
          document,
          assetsByID,
          containerWidth,
          options,
          onProgress: setExportProgress,
        });
      } else {
        try {
          result = await apiClient.exportBoardFigma(document.id, options);
        } catch {
          const { exportFigmaBridgeInBrowser } = await import('../../lib/client-board-export');
          result = await exportFigmaBridgeInBrowser({
            document,
            assetsByID,
            containerWidth,
            options,
            onProgress: setExportProgress,
          });
        }
      }
      triggerDownloadBlob(result.blob, result.filename || `${safeSlug}.charkleboard`);
      if (result.report) {
        setFigmaReport(result.report);
      } else {
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
      setExportProgress(null);
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
          导出情绪板
        </span>
      }
      subtitle={`「${document.title}」 · ${document.nodes.length} 项`}
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
            Figma / FigJam (.charkleboard)
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
                    PNG 清晰度更高，JPG 文件更小
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
                    推荐使用 2× 高清倍率导出
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

              <div className="flex items-center justify-between gap-4">
                <div>
                  <div className="text-[13px] font-medium text-[var(--text-primary)]">画布背景</div>
                  <div className="text-[11.5px] text-[var(--text-secondary)]">
                    PNG 支持透明背景，方便直接嵌入设计稿
                  </div>
                </div>
                <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
                  {(
                    [
                      { id: 'light', label: '浅色' },
                      { id: 'dark', label: '深色' },
                      { id: 'transparent', label: '透明' },
                    ] as const
                  ).map((bg) => {
                    const disabled = bg.id === 'transparent' && format === 'jpeg';
                    const active = effectiveImageBackground === bg.id;
                    return (
                      <button
                        key={bg.id}
                        type="button"
                        disabled={disabled}
                        onClick={() => setBackgroundMode(bg.id)}
                        className={[
                          'px-3 py-1 rounded-[6px] text-[12px] font-medium cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed',
                          active
                            ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                            : 'text-[var(--text-secondary)]',
                        ].join(' ')}
                      >
                        {bg.label}
                      </button>
                    );
                  })}
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

            {tab === 'figma' && (
              <label className="inline-flex items-center gap-2 text-[12.5px] text-[var(--text-primary)] cursor-pointer">
                <input
                  type="checkbox"
                  checked={darkAppearance}
                  onChange={(e) => setBackgroundMode(e.target.checked ? 'dark' : 'light')}
                  className="accent-[var(--accent)] rounded"
                />
                深色画布背景
              </label>
            )}
          </div>
        </div>

        {/* Live Browser Export Progress Bar */}
        {busyAction && exportProgress && (
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] px-3.5 py-2.5 flex flex-col gap-1.5">
            <div className="flex items-center justify-between text-[12px]">
              <span className="text-[var(--text-primary)] font-medium truncate">
                {exportProgress.stage}
              </span>
              <span className="font-mono text-[11px] text-[var(--text-secondary)] tabular-nums shrink-0">
                {exportProgress.total > 0
                  ? `${Math.min(100, Math.round((exportProgress.completed / exportProgress.total) * 100))}%`
                  : ''}
              </span>
            </div>
            <div className="h-1.5 w-full rounded-full bg-[var(--bg-subtle)] overflow-hidden">
              <div
                className="h-full bg-[var(--accent)] transition-[width] duration-200 ease-[var(--ease-out)]"
                style={{
                  width: `${
                    exportProgress.total > 0
                      ? Math.max(8, Math.min(100, (exportProgress.completed / exportProgress.total) * 100))
                      : 30
                  }%`,
                }}
              />
            </div>
          </div>
        )}

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
                    Figma / FigJam 迁移包 (.charkleboard)
                  </div>
                  <p className="text-[12px] text-[var(--text-secondary)] mt-0.5 leading-relaxed">
                    保留独立图片图层、动态 GIF、可编辑便签、分组框、箭头连线与手绘笔迹，支持离线导入 Figma / FigJam。
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
              <div className="flex flex-wrap items-center justify-between gap-2 mb-3">
                <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
                  3 步导入 Figma / FigJam（随仓库内置插件 <code className="font-mono text-[11.5px] px-1.5 py-0.5 rounded bg-[var(--bg-subtle)]">figma-plugin/</code>）
                </div>
                <button
                  type="button"
                  onClick={() => {
                    onClose();
                    openSettings('extensions');
                  }}
                  className="charkle-pressable inline-flex items-center gap-1 px-2.5 py-1 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11.5px] font-medium text-[var(--accent)] hover:border-[var(--accent-ring)] cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
                >
                  打开插件与扩展设置 →
                </button>
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
