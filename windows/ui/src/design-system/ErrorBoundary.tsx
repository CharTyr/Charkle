import React from 'react';
import { AlertTriangle, ChevronRight, RefreshCw, RotateCcw } from 'lucide-react';

export interface ErrorBoundaryProps {
  children: React.ReactNode;
  /** Compact presentation for small utility windows (drop shelf, capture overlay). */
  compact?: boolean;
  /** Optional custom heading shown in the recovery card. */
  title?: string;
}

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
  showDetails: boolean;
}

/**
 * Top-level React crash boundary preventing white-screen freezes across Charkle Windows
 * entry points (main workspace, top-edge drop shelf, region capture overlay).
 */
export class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      showDetails: false,
    };
  }

  static getDerivedStateFromError(error: Error): Partial<ErrorBoundaryState> {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo): void {
    console.error('[Charkle ErrorBoundary]', error, info.componentStack);
  }

  private handleReload = (): void => {
    window.location.reload();
  };

  private handleReset = (): void => {
    this.setState({ hasError: false, error: null, showDetails: false });
  };

  render(): React.ReactNode {
    if (!this.state.hasError) {
      return this.props.children;
    }

    const { compact = false, title = '界面遇到意外中断' } = this.props;
    const { error, showDetails } = this.state;

    if (compact) {
      return (
        <div
          role="alert"
          className="w-full h-full flex items-center justify-center p-3 bg-transparent"
        >
          <div className="charkle-glass-dark rounded-[var(--radius-popover-outer)] px-3.5 py-2.5 flex items-center gap-3 text-[12.5px] text-white max-w-[360px]">
            <AlertTriangle size={16} className="text-[var(--warning)] shrink-0" />
            <span className="truncate flex-1">{title}</span>
            <button
              type="button"
              onClick={this.handleReload}
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1 rounded-[var(--radius-chip)] bg-[var(--accent)] text-white text-[11.5px] font-medium cursor-pointer shrink-0"
            >
              <RefreshCw size={12} />
              重新加载
            </button>
          </div>
        </div>
      );
    }

    return (
      <div
        role="alert"
        className="w-screen h-screen flex items-center justify-center p-6 bg-[var(--bg-gallery)] text-[var(--text-primary)] select-none"
      >
        <div className="w-full max-w-[420px] rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-[var(--shadow-modal)] p-6 flex flex-col gap-4">
          <div className="flex items-start gap-3">
            <div className="h-10 w-10 rounded-[var(--radius-dock-inner)] bg-[var(--warning-soft)] text-[var(--warning)] flex items-center justify-center shrink-0">
              <AlertTriangle size={20} />
            </div>
            <div className="min-w-0 flex-1">
              <h1 className="text-[15px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] charkle-heading">
                {title}
              </h1>
              <p className="mt-1 text-[12.5px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
                你的素材与情绪板数据已安全保存在本地，重新加载界面即可继续工作。
              </p>
            </div>
          </div>

          <div className="flex items-center justify-end gap-2 pt-1">
            <button
              type="button"
              onClick={this.handleReset}
              className="charkle-pressable h-8 px-3 inline-flex items-center gap-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] text-[var(--text-primary)] border border-[var(--border-hairline)] hover:bg-[var(--border-hairline)] text-[12.5px] font-medium cursor-pointer"
            >
              <RotateCcw size={13.5} />
              尝试恢复
            </button>
            <button
              type="button"
              onClick={this.handleReload}
              className="charkle-pressable h-8 px-3.5 inline-flex items-center gap-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white text-[12.5px] font-medium cursor-pointer"
            >
              <RefreshCw size={13.5} />
              重新加载界面
            </button>
          </div>

          {error?.message && (
            <div className="pt-2 border-t border-[var(--border-hairline)]">
              <button
                type="button"
                aria-expanded={showDetails}
                onClick={() => this.setState((s) => ({ showDetails: !s.showDetails }))}
                className="w-full min-h-[28px] px-1.5 -mx-1.5 flex items-center gap-1.5 rounded-[var(--radius-chip)] text-[11.5px] text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <ChevronRight
                  size={12}
                  className="shrink-0 transition-transform duration-200"
                  style={{ transform: showDetails ? 'rotate(90deg)' : 'rotate(0deg)' }}
                />
                <span>查看错误摘要</span>
              </button>
              {showDetails && (
                <pre className="mt-2 p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] text-[11px] text-[var(--text-secondary)] charkle-mono charkle-wrap-safe whitespace-pre-wrap max-h-[140px] overflow-y-auto charkle-scroll select-text">
                  {error.message}
                </pre>
              )}
            </div>
          )}
        </div>
      </div>
    );
  }
}
