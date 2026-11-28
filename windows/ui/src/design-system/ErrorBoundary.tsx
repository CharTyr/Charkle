import React from 'react';
import {
  ArrowClockwise16Regular,
  ArrowCounterclockwise16Regular,
  ChevronRight16Regular,
  Warning20Regular,
} from '@fluentui/react-icons';

export interface ErrorBoundaryProps {
  children: React.ReactNode;
  /** Compact presentation for small utility windows (drop shelf, capture overlay). */
  compact?: boolean;
  /** Whether to occupy full viewport (`w-screen h-screen`) or fill parent container (`w-full h-full`). */
  fullScreen?: boolean;
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

    const { compact = false, fullScreen = true, title = '界面遇到意外中断' } = this.props;
    const { error, showDetails } = this.state;

    if (compact) {
      return (
        <div
          role="alert"
          className="w-full h-full flex items-center justify-center p-3 bg-transparent"
        >
          <div className="win-acrylic-dark rounded-[var(--win-radius-overlay)] px-3.5 py-2.5 flex items-center gap-3 text-[12.5px] text-white max-w-[360px]">
            <Warning20Regular className="w-4 h-4 text-[var(--warning)] shrink-0" />
            <span className="truncate flex-1">{title}</span>
            <button
              type="button"
              onClick={this.handleReload}
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1 rounded-[var(--win-radius-control)] bg-[var(--accent)] text-[var(--accent-text)] text-[12px] font-medium cursor-pointer shrink-0"
            >
              <ArrowClockwise16Regular className="w-3.5 h-3.5" />
              重新加载
            </button>
          </div>
        </div>
      );
    }

    return (
      <div
        role="alert"
        className={[
          fullScreen ? 'w-screen h-screen' : 'w-full h-full',
          'flex items-center justify-center p-6 bg-[var(--bg-gallery)] text-[var(--text-primary)] select-none',
        ].join(' ')}
      >
        <div className="w-full max-w-[420px] rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)] p-6 flex flex-col gap-4">
          <div className="flex items-start gap-3">
            <div className="h-10 w-10 rounded-[var(--win-radius-card)] bg-[var(--warning-soft)] text-[var(--warning)] flex items-center justify-center shrink-0">
              <Warning20Regular className="w-5 h-5" />
            </div>
            <div className="min-w-0 flex-1">
              <h1 className="text-[16px] leading-[22px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] charkle-heading">
                {title}
              </h1>
              <p className="mt-1 text-[13px] leading-[18px] text-[var(--text-secondary)] charkle-prose">
                你的素材与情绪板数据已安全保存在本地，重新加载界面即可继续工作。
              </p>
            </div>
          </div>

          <div className="flex items-center justify-end gap-2 pt-1">
            <button
              type="button"
              onClick={this.handleReset}
              className="charkle-pressable win-control-elevation h-8 px-3 inline-flex items-center gap-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] text-[var(--text-primary)] hover:bg-[var(--win-control-fill-hover)] text-[13px] font-medium cursor-pointer"
            >
              <ArrowCounterclockwise16Regular className="w-3.5 h-3.5" />
              尝试恢复
            </button>
            <button
              type="button"
              onClick={this.handleReload}
              className="charkle-pressable win-accent-elevation h-8 px-3.5 inline-flex items-center gap-1.5 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[13px] font-medium cursor-pointer"
            >
              <ArrowClockwise16Regular className="w-3.5 h-3.5" />
              重新加载界面
            </button>
          </div>

          {error?.message && (
            <div className="pt-2 border-t border-[var(--win-stroke-divider)]">
              <button
                type="button"
                aria-expanded={showDetails}
                onClick={() => this.setState((s) => ({ showDetails: !s.showDetails }))}
                className="w-full min-h-[28px] px-1.5 -mx-1.5 flex items-center gap-1.5 rounded-[var(--win-radius-control)] text-[12px] text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer text-left"
              >
                <ChevronRight16Regular
                  className="w-3.5 h-3.5 shrink-0 transition-transform duration-[167ms] ease-[var(--win-ease-out)]"
                  style={{ transform: showDetails ? 'rotate(90deg)' : 'rotate(0deg)' }}
                />
                <span>查看错误摘要</span>
              </button>
              {showDetails && (
                <pre className="mt-2 p-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] text-[11px] text-[var(--text-secondary)] charkle-mono charkle-wrap-safe whitespace-pre-wrap max-h-[140px] overflow-y-auto charkle-scroll select-text">
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
