import type { CharkleSSEEvent } from '@charkle/shared';
import { API_BASE } from './client';

export type SSEEventHandler = (event: CharkleSSEEvent) => void;

export interface CharkleSSEConnection {
  disconnect: () => void;
}

const KNOWN_SSE_EVENT_TYPES = [
  'sync.status',
  'sync.completed',
  'library.changed',
  'library.enriched',
  'board.updated',
  'ai.curate.step',
  'ping',
] as const;

/**
 * Authenticated auto-reconnecting SSE client for `/api/v1/events`.
 * Supports both default unnamed `message` frames and named SSE event frames.
 */
export function connectCharkleSSE(
  onEvent: SSEEventHandler,
  options?: {
    onConnectionChange?: (connected: boolean) => void;
    onUnauthorized?: () => void;
  },
): CharkleSSEConnection {
  let disposed = false;
  let source: EventSource | null = null;
  let reconnectTimer: number | null = null;
  let attempt = 0;

  const dispatchRaw = (rawData: string) => {
    try {
      const parsed = JSON.parse(rawData) as CharkleSSEEvent;
      if (parsed && typeof parsed.type === 'string') {
        onEvent(parsed);
      }
    } catch {
      // Ignore malformed heartbeat frames
    }
  };

  const scheduleReconnect = () => {
    if (disposed) return;
    if (reconnectTimer !== null) {
      window.clearTimeout(reconnectTimer);
    }
    const delayMs = Math.min(15_000, 1000 * Math.pow(1.6, attempt));
    attempt += 1;
    reconnectTimer = window.setTimeout(() => {
      if (!disposed) open();
    }, delayMs);
  };

  const open = () => {
    if (disposed) return;
    if (source) {
      source.close();
      source = null;
    }

    const es = new EventSource(`${API_BASE}/events`, { withCredentials: true });
    source = es;

    es.onopen = () => {
      attempt = 0;
      options?.onConnectionChange?.(true);
    };

    es.onmessage = (msg) => {
      dispatchRaw(msg.data);
    };

    for (const typeName of KNOWN_SSE_EVENT_TYPES) {
      es.addEventListener(typeName, (ev) => {
        const messageEvent = ev as MessageEvent<string>;
        dispatchRaw(messageEvent.data);
      });
    }

    es.onerror = () => {
      options?.onConnectionChange?.(false);
      es.close();
      source = null;

      // Probe auth status briefly when repeated failures occur to catch session expiry cleanly
      if (attempt >= 2 && options?.onUnauthorized) {
        fetch(`${API_BASE}/auth/status`, { credentials: 'include' })
          .then((r) => (r.ok ? r.json() : null))
          .then((status: { authenticated?: boolean } | null) => {
            if (status && status.authenticated === false) {
              disposed = true;
              options.onUnauthorized?.();
            } else {
              scheduleReconnect();
            }
          })
          .catch(() => scheduleReconnect());
      } else {
        scheduleReconnect();
      }
    };
  };

  open();

  return {
    disconnect() {
      disposed = true;
      if (reconnectTimer !== null) {
        window.clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      if (source) {
        source.close();
        source = null;
      }
      options?.onConnectionChange?.(false);
    },
  };
}
