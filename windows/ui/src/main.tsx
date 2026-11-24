import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import {
  applySavedGlassTintScales,
  ErrorBoundary,
  startLiquidGlassController,
} from './design-system';
import { App } from './App';

applySavedGlassTintScales();
startLiquidGlassController({ rim: 40, edge: 1.35, power: 2.1, dispersion: 0.20 });

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>,
);
