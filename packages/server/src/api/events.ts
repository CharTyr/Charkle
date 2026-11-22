import type {
  CharkleSSEEvent,
  MoodboardAgentStep,
  SyncReport,
  SyncStatus,
  UUID,
} from '@charkle/shared';

export type EventListener = (event: CharkleSSEEvent) => void;

/**
 * In-process typed pub/sub bus powering SSE `/api/v1/events`.
 */
export class EventBus {
  private readonly listeners = new Set<EventListener>();

  subscribe(listener: EventListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  subscriberCount(): number {
    return this.listeners.size;
  }

  emit(event: CharkleSSEEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch {
        // Isolate subscriber failures so one dropped client never breaks fan-out.
      }
    }
  }

  emitLibraryChanged(reason: string, assetIDs?: UUID[], folderIDs?: UUID[]): void {
    this.emit({
      type: 'library.changed',
      reason,
      ...(assetIDs && assetIDs.length > 0 ? { assetIDs } : {}),
      ...(folderIDs && folderIDs.length > 0 ? { folderIDs } : {}),
      timestamp: new Date().toISOString(),
    });
  }

  emitLibraryEnriched(assetIDs: UUID[]): void {
    this.emit({
      type: 'library.enriched',
      assetIDs,
      count: assetIDs.length,
      timestamp: new Date().toISOString(),
    });
  }

  emitBoardUpdated(boardID: UUID, deleted = false): void {
    this.emit({
      type: 'board.updated',
      boardID,
      ...(deleted ? { deleted: true } : {}),
      timestamp: new Date().toISOString(),
    });
  }

  emitSyncStatus(status: SyncStatus): void {
    this.emit({
      type: 'sync.status',
      status,
      timestamp: new Date().toISOString(),
    });
  }

  emitSyncCompleted(report: SyncReport, status: SyncStatus): void {
    this.emit({
      type: 'sync.completed',
      report,
      status,
      timestamp: new Date().toISOString(),
    });
  }

  emitAICurateStep(requestID: string, step: MoodboardAgentStep): void {
    this.emit({
      type: 'ai.curate.step',
      requestID,
      step,
      timestamp: new Date().toISOString(),
    });
  }

  emitPing(): void {
    this.emit({
      type: 'ping',
      timestamp: new Date().toISOString(),
    });
  }
}
