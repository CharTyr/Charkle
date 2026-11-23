import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import { TopEdgeDropShelf } from './features/shelf/TopEdgeDropShelf';

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <TopEdgeDropShelf />
  </React.StrictMode>,
);
