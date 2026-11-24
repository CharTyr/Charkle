import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import { ErrorBoundary, FluentMotionProvider } from './design-system';
import { RegionCaptureOverlay } from './features/capture/RegionCaptureOverlay';

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <FluentMotionProvider>
      <ErrorBoundary compact title="截图工具遇到意外中断">
        <RegionCaptureOverlay />
      </ErrorBoundary>
    </FluentMotionProvider>
  </React.StrictMode>,
);
