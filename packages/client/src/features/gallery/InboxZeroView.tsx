import React from 'react';
import { Button, CharkleIcon } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';

export const InboxZeroView: React.FC = () => {
  const navigate = useCoordinatorStore((s) => s.navigate);

  return (
    <div className="flex-1 flex flex-col items-center justify-center p-10 text-center charkle-modal-panel">
      <div
        className="mb-4"
        style={{
          animation: 'charkle-modal-panel-enter 240ms var(--ease-out-strong) 45ms both',
        }}
      >
        <CharkleIcon name="inbox" style="layered" size={84} />
      </div>

      <h2 className="text-[17px] font-semibold tracking-[-0.015em] text-[var(--text-primary)]">
        收件箱已清空
      </h2>

      <div className="flex items-center gap-2.5 mt-5">
        <Button variant="primary" size="sm" onClick={() => navigate({ type: 'allItems' })}>
          浏览全部素材
        </Button>
        <Button variant="secondary" size="sm" onClick={() => navigate({ type: 'moodboardsHome' })}>
          打开情绪板
        </Button>
      </div>
    </div>
  );
};
