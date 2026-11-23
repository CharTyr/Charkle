import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import { RegionCaptureOverlay } from './features/capture/RegionCaptureOverlay';

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <RegionCaptureOverlay />
  </React.StrictMode>,
);
