import React, { useEffect, useRef, useState } from 'react';
import { AlertTriangle } from 'lucide-react';
import { Button } from './Button';
import { ModalShell } from './ModalShell';

export interface ConfirmDialogProps {
  open: boolean;
  onClose: () => void;
  onConfirm: () => void | Promise<void>;
  title: string;
  description?: React.ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  tone?: 'danger' | 'primary';
  loading?: boolean;
}

/**
 * Reusable confirmation dialog for irreversible destructive actions (e.g. permanent delete,
 * smart folder deletion, token/session revocation). Built on `ModalShell` so backdrop veil,
 * focus isolation, Escape handling, and 170ms `--ease-out` exit animations stay consistent.
 */
export const ConfirmDialog: React.FC<ConfirmDialogProps> = ({
  open,
  onClose,
  onConfirm,
  title,
  description,
  confirmLabel = '确认删除',
  cancelLabel = '取消',
  tone = 'danger',
  loading = false,
}) => {
  const [submitting, setSubmitting] = useState(false);
  const cancelBtnRef = useRef<HTMLButtonElement | null>(null);
  const busy = loading || submitting;

  useEffect(() => {
    if (!open) {
      setSubmitting(false);
      return;
    }
    const raf = requestAnimationFrame(() => {
      cancelBtnRef.current?.focus();
    });
    return () => cancelAnimationFrame(raf);
  }, [open]);

  const handleConfirm = async () => {
    if (busy) return;
    setSubmitting(true);
    try {
      await onConfirm();
      onClose();
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (!busy) onClose();
      }}
      width="sm"
      hideCloseButton
      closeOnBackdrop={!busy}
      noPadding
    >
      <div className="p-5 flex items-start gap-3.5">
        <div
          className={[
            'h-9 w-9 rounded-[var(--radius-settings-inner)] shrink-0 flex items-center justify-center',
            tone === 'danger'
              ? 'bg-[var(--danger-soft)] text-[var(--danger)]'
              : 'bg-[var(--accent-soft)] text-[var(--accent)]',
          ].join(' ')}
        >
          <AlertTriangle size={18} />
        </div>
        <div className="min-w-0 flex-1 pt-0.5">
          <h3 className="text-[14.5px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] leading-snug">
            {title}
          </h3>
          {description && (
            <div className="mt-1.5 text-[12.5px] leading-relaxed text-[var(--text-secondary)]">
              {description}
            </div>
          )}
        </div>
      </div>

      <div className="flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border-hairline)] bg-[var(--bg-gallery)]/50">
        <Button
          ref={cancelBtnRef}
          variant="secondary"
          size="sm"
          disabled={busy}
          onClick={onClose}
        >
          {cancelLabel}
        </Button>
        <Button
          variant={tone === 'danger' ? 'danger' : 'primary'}
          size="sm"
          loading={busy}
          onClick={() => void handleConfirm()}
        >
          {confirmLabel}
        </Button>
      </div>
    </ModalShell>
  );
};
