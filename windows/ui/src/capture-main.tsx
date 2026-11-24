import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import {
  applySavedGlassTintScales,
  ErrorBoundary,
  startLiquidGlassController,
} from './design-system';
import { RegionCaptureOverlay } from './features/capture/RegionCaptureOverlay';

applySavedGlassTintScales();
startLiquidGlassController({ rim: 30, edge: 1.05, power: 2.6, dispersion: 0.14 });

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <ErrorBoundary compact title="截图工具遇到意外中断">
      <RegionCaptureOverlay />
    </ErrorBoundary>
  </React.StrictMode>,
);
