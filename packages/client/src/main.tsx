import { createRoot } from 'react-dom/client';
import type { MediaKind } from '@charkle/shared';

const defaultKind: MediaKind = 'image';

const rootEl = document.getElementById('root');
if (rootEl) {
  createRoot(rootEl).render(
    <main data-charkle-stub={defaultKind}>Charkle Web</main>,
  );
}
