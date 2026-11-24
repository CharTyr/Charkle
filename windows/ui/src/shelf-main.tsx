import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import { ErrorBoundary, FluentMotionProvider, TooltipProvider } from './design-system';
import { TopEdgeDropShelf } from './features/shelf/TopEdgeDropShelf';

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <FluentMotionProvider>
      <TooltipProvider>
        <ErrorBoundary compact title="悬浮窗遇到意外中断">
          <TopEdgeDropShelf />
        </ErrorBoundary>
      </TooltipProvider>
    </FluentMotionProvider>
  </React.StrictMode>,
);
