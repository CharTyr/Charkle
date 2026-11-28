import React, { useEffect, useRef, useState } from 'react';
import {
  ChevronLeft16Regular,
  ChevronRight16Regular,
  DocumentText24Regular,
  ZoomIn16Regular,
  ZoomOut16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface PdfDocumentViewerProps {
  asset: AssetRecord;
}

/**
 * Multi-page HiDPI PDF Quick Look viewer with graceful fallback.
 */
export const PdfDocumentViewer: React.FC<PdfDocumentViewerProps> = ({ asset }) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const [pageNumber, setPageNumber] = useState(1);
  const [numPages, setNumPages] = useState(0);
  const [scale, setScale] = useState(1.25);
  const [error, setError] = useState<string | null>(null);
  const pdfDocRef = useRef<{
    numPages: number;
    destroy?: () => Promise<void> | void;
    getPage: (n: number) => Promise<{
      getViewport: (opts: { scale: number }) => { width: number; height: number };
      render: (opts: {
        canvasContext: CanvasRenderingContext2D;
        viewport: unknown;
      }) => { promise: Promise<void>; cancel?: () => void };
      cleanup?: () => void;
    }>;
  } | null>(null);
  const renderTaskRef = useRef<{ promise: Promise<void>; cancel?: () => void } | null>(null);
  const activePageRef = useRef<{ cleanup?: () => void } | null>(null);

  useEffect(() => {
    let cancelled = false;
    let loadingTask: { promise: Promise<unknown>; destroy?: () => Promise<void> | void } | null =
      null;
    setError(null);
    setPageNumber(1);
    setNumPages(0);
    setScale(1.25);

    const prevDoc = pdfDocRef.current;
    pdfDocRef.current = null;
    if (prevDoc?.destroy) {
      void Promise.resolve(prevDoc.destroy()).catch(() => {});
    }

    const load = async () => {
      try {
        const pdfjs = await import('pdfjs-dist');
        if (cancelled) return;
        pdfjs.GlobalWorkerOptions.workerSrc = new URL(
          'pdfjs-dist/build/pdf.worker.min.mjs',
          import.meta.url,
        ).toString();
        const task = pdfjs.getDocument(getTransport().originalUrl(asset.id));
        loadingTask = task as unknown as typeof loadingTask;
        const doc = await task.promise;
        if (cancelled) {
          void Promise.resolve(
            (doc as unknown as { destroy?: () => Promise<void> | void }).destroy?.(),
          ).catch(() => {});
          return;
        }
        pdfDocRef.current = doc as unknown as typeof pdfDocRef.current;
        setNumPages(doc.numPages);
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'PDF 预览加载失败');
        }
      }
    };
    void load();
    return () => {
      cancelled = true;
      renderTaskRef.current?.cancel?.();
      renderTaskRef.current = null;
      activePageRef.current?.cleanup?.();
      activePageRef.current = null;
      if (loadingTask?.destroy) {
        void Promise.resolve(loadingTask.destroy()).catch(() => {});
      }
      const activeDoc = pdfDocRef.current;
      pdfDocRef.current = null;
      if (activeDoc?.destroy) {
        void Promise.resolve(activeDoc.destroy()).catch(() => {});
      }
      const canvas = canvasRef.current;
      if (canvas) {
        canvas.width = 0;
        canvas.height = 0;
      }
    };
  }, [asset.id]);

  useEffect(() => {
    let cancelled = false;
    const doc = pdfDocRef.current;
    const canvas = canvasRef.current;
    if (!doc || !canvas || numPages === 0) return;

    const renderPage = async () => {
      let currentPage: { cleanup?: () => void } | null = null;
      let currentTask: { promise: Promise<void>; cancel?: () => void } | null = null;
      try {
        const prevTask = renderTaskRef.current;
        renderTaskRef.current = null;
        if (prevTask) {
          prevTask.cancel?.();
          await prevTask.promise.catch(() => {});
        }
        activePageRef.current?.cleanup?.();
        activePageRef.current = null;
        if (cancelled) return;

        const page = await doc.getPage(pageNumber);
        currentPage = page;
        if (cancelled) {
          page.cleanup?.();
          return;
        }
        activePageRef.current = page;

        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const cssViewport = page.getViewport({ scale });
        const renderViewport = page.getViewport({ scale: scale * dpr });
        canvas.width = Math.round(renderViewport.width);
        canvas.height = Math.round(renderViewport.height);
        canvas.style.width = `${Math.round(cssViewport.width)}px`;
        canvas.style.height = `${Math.round(cssViewport.height)}px`;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        const task = page.render({ canvasContext: ctx, viewport: renderViewport });
        currentTask = task;
        renderTaskRef.current = task;
        await task.promise;
      } catch (err) {
        const isRenderCancelled =
          err instanceof Error && err.name === 'RenderingCancelledException';
        if (!cancelled && !isRenderCancelled) {
          setError(err instanceof Error ? err.message : '渲染 PDF 页面失败');
        }
      } finally {
        if (currentTask && renderTaskRef.current === currentTask) {
          renderTaskRef.current = null;
        }
        if (currentPage) {
          currentPage.cleanup?.();
          if (activePageRef.current === currentPage) {
            activePageRef.current = null;
          }
        }
      }
    };
    void renderPage();
    return () => {
      cancelled = true;
      renderTaskRef.current?.cancel?.();
    };
  }, [asset.id, pageNumber, scale, numPages]);

  if (error) {
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-w-[460px] mx-auto p-6 rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] text-center flex flex-col items-center gap-3 shadow-2xl"
      >
        <DocumentText24Regular className="w-7 h-7 text-[var(--text-tertiary)]" />
        <div className="text-[14px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
        <p className="text-[12.5px] text-[var(--text-secondary)]">
          当前文档暂无法内嵌渲染，可在资源管理器中打开查看。
        </p>
        <Button
          variant="accent"
          size="sm"
          onClick={() => void getTransport().revealInExplorer(asset.id)}
        >
          在资源管理器中显示
        </Button>
      </div>
    );
  }

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      className="w-full h-full flex flex-col items-center overflow-hidden"
    >
      <div className="flex-1 w-full overflow-auto charkle-scroll flex justify-center p-6">
        <canvas
          ref={canvasRef}
          className="rounded-[var(--win-radius-card)] shadow-2xl bg-white self-start"
        />
      </div>

      {numPages > 0 && (
        <div className="win-acrylic-dark mb-4 rounded-[var(--win-radius-overlay)] px-2.5 py-1 flex items-center gap-1.5 text-[12px]">
          <button
            type="button"
            aria-label="上一页"
            disabled={pageNumber <= 1}
            onClick={() => setPageNumber((p) => Math.max(1, p - 1))}
            className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--win-radius-control)] hover:bg-white/10 disabled:opacity-40 cursor-pointer"
          >
            <ChevronLeft16Regular className="w-4 h-4" />
          </button>
          <span className="px-1 charkle-tabular">
            {pageNumber} / {numPages}
          </span>
          <button
            type="button"
            aria-label="下一页"
            disabled={pageNumber >= numPages}
            onClick={() => setPageNumber((p) => Math.min(numPages, p + 1))}
            className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--win-radius-control)] hover:bg-white/10 disabled:opacity-40 cursor-pointer"
          >
            <ChevronRight16Regular className="w-4 h-4" />
          </button>
          <div className="h-4 w-px bg-white/15 mx-0.5" />
          <button
            type="button"
            aria-label="缩小页面"
            onClick={() => setScale((s) => Math.max(0.6, Number((s - 0.25).toFixed(2))))}
            className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--win-radius-control)] hover:bg-white/10 cursor-pointer"
          >
            <ZoomOut16Regular className="w-4 h-4" />
          </button>
          <button
            type="button"
            aria-label="放大页面"
            onClick={() => setScale((s) => Math.min(3, Number((s + 0.25).toFixed(2))))}
            className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--win-radius-control)] hover:bg-white/10 cursor-pointer"
          >
            <ZoomIn16Regular className="w-4 h-4" />
          </button>
        </div>
      )}
    </div>
  );
};
