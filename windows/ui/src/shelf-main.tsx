import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import {
  applySavedGlassTintScales,
  ErrorBoundary,
  startLiquidGlassController,
} from './design-system';
import { TopEdgeDropShelf } from './features/shelf/TopEdgeDropShelf';

applySavedGlassTintScales();
startLiquidGlassController({ rim: 30, edge: 1.0, power: 2.6, dispersion: 0.14 });

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <ErrorBoundary compact title="悬浮窗遇到意外中断">
      <TopEdgeDropShelf />
    </ErrorBoundary>
  </React.StrictMode>,
);
