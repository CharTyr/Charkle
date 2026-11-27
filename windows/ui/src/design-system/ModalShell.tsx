import React from 'react';
import { Dialog as BaseDialog } from '@base-ui/react/dialog';
import { Dismiss16Regular } from '@fluentui/react-icons';

export type ModalWidth = 'sm' | 'md' | 'lg' | 'xl' | 'studio';

const WIDTH_CLASS: Record<ModalWidth, string> = {
  sm: 'max-w-[420px]',
  md: 'max-w-[540px]',
  lg: 'max-w-[740px]',
  xl: 'max-w-[920px]',
  studio: 'max-w-[1040px]',
};

export interface ModalShellProps {
  open: boolean;
  onClose: () => void;
  title?: React.ReactNode;
  subtitle?: React.ReactNode;
  width?: ModalWidth;
  headerRight?: React.ReactNode;
  footer?: React.ReactNode;
  noPadding?: boolean;
  hideCloseButton?: boolean;
  closeOnBackdrop?: boolean;
  /** True for 0ms instant modals like Ctrl+J Jump Anywhere (fluent2-design-system.md §6.1). */
  instant?: boolean;
  /** Optional base z-index (default 100) so nested confirmation dialogs stay above higher-z overlays (e.g. Dedup z-[115]). */
  zIndexBase?: number;
  ariaLabel?: string;
  className?: string;
  children: React.ReactNode;
}

const stopModalPropagation = {
  onMouseDown: (e: React.MouseEvent) => e.stopPropagation(),
  onPointerDown: (e: React.PointerEvent) => e.stopPropagation(),
  onClick: (e: React.MouseEvent) => e.stopPropagation(),
  onDoubleClick: (e: React.MouseEvent) => e.stopPropagation(),
  onContextMenu: (e: React.MouseEvent) => e.stopPropagation(),
};

/**
 * Fluent 2 Desktop `ContentDialog` shell built on `@base-ui/react/dialog`:
 * - Built-in focus trap, Esc stacking, and focus restoration on close
 * - Smoke backdrop scrim (no expensive full-screen blur)
 * - 10px dialog radius, 1px flyout stroke, subtle ContentDialog footer bar
 * - `instant` prop disables entry/exit motion for 0ms high-frequency modals (Ctrl+J)
 */
export const ModalShell: React.FC<ModalShellProps> = ({
  open,
  onClose,
  title,
  subtitle,
  width = 'md',
  headerRight,
  footer,
  noPadding = false,
  hideCloseButton = false,
  closeOnBackdrop = true,
  instant = false,
  zIndexBase,
  ariaLabel,
  className = '',
  children,
}) => (
  <BaseDialog.Root
    open={open}
    modal={true}
    disablePointerDismissal={!closeOnBackdrop}
    onOpenChange={(nextOpen, details) => {
      if (nextOpen) return;
      if (
        details.reason === 'escape-key' &&
        typeof document !== 'undefined' &&
        document.querySelector('[data-charkle-popover-open="true"]')
      ) {
        details.cancel();
        return;
      }
      onClose();
    }}
  >
    <BaseDialog.Portal>
      <BaseDialog.Backdrop
        style={zIndexBase !== undefined ? { zIndex: zIndexBase } : undefined}
        className={[
          'win-smoke-scrim fixed inset-0 z-[100]',
          instant ? '' : 'win-dialog-backdrop',
        ]
          .filter(Boolean)
          .join(' ')}
        {...stopModalPropagation}
      />

      <BaseDialog.Viewport
        style={zIndexBase !== undefined ? { zIndex: zIndexBase + 1 } : undefined}
        className="fixed inset-0 z-[101] flex items-center justify-center p-4 sm:p-6 pointer-events-none"
        {...stopModalPropagation}
      >
        <BaseDialog.Popup
          aria-label={!title ? ariaLabel : undefined}
          className={[
            instant ? '' : 'win-dialog-popup',
            'pointer-events-auto relative w-full flex flex-col max-h-[90vh] overflow-hidden outline-none',
            'rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)]',
            'border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)]',
            WIDTH_CLASS[width],
            className,
          ]
            .filter(Boolean)
            .join(' ')}
          {...stopModalPropagation}
        >
          {(title || !hideCloseButton || headerRight) && (
            <div className="flex items-center justify-between gap-3 px-5 py-3.5 border-b border-[var(--win-stroke-divider)] shrink-0">
              <div className="min-w-0">
                {title && (
                  <BaseDialog.Title className="text-[18px] leading-[24px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate charkle-heading">
                    {title}
                  </BaseDialog.Title>
                )}
                {subtitle && (
                  <BaseDialog.Description className="text-[12px] leading-[16px] text-[var(--text-secondary)] mt-0.5 truncate">
                    {subtitle}
                  </BaseDialog.Description>
                )}
              </div>
              <div className="flex items-center gap-2 shrink-0">
                {headerRight}
                {!hideCloseButton && (
                  <BaseDialog.Close
                    aria-label="关闭"
                    className="charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] cursor-pointer focus-visible:outline-2 focus-visible:outline-[var(--accent)]"
                  >
                    <Dismiss16Regular className="w-4 h-4" />
                  </BaseDialog.Close>
                )}
              </div>
            </div>
          )}

          <div className={`flex-1 min-h-0 overflow-y-auto charkle-scroll ${noPadding ? '' : 'p-5'}`}>
            {children}
          </div>

          {footer && (
            <div className="flex items-center justify-end gap-2 px-5 py-3.5 border-t border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/55 shrink-0">
              {footer}
            </div>
          )}
        </BaseDialog.Popup>
      </BaseDialog.Viewport>
    </BaseDialog.Portal>
  </BaseDialog.Root>
);
