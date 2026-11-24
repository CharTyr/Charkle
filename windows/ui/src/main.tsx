import React from 'react';
import ReactDOM from 'react-dom/client';
import './design-system/tokens.css';
import { ErrorBoundary, FluentMotionProvider, TooltipProvider } from './design-system';
import { App } from './App';
import { useCoordinatorStore } from './stores/coordinatorStore';

const MainRoot: React.FC = () => {
  const animationsDisabled = useCoordinatorStore(
    (s) => s.surfaceState?.animationsEnabled === false,
  );
  return (
    <FluentMotionProvider animationsDisabled={animationsDisabled}>
      <TooltipProvider>
        <ErrorBoundary>
          <App />
        </ErrorBoundary>
      </TooltipProvider>
    </FluentMotionProvider>
  );
};

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <MainRoot />
  </React.StrictMode>,
);
