/**
 * Charkle Extension — Early Document-Start Loader for Multi-Platform Passive Feed Observer
 * Runs strictly on X, Bluesky, Threads, and Instagram top frames so even page-1 media responses are captured.
 */
(() => {
  if (window !== window.top) return;
  if (window.__charkleXBridgeLoaderRan) return;
  window.__charkleXBridgeLoaderRan = true;

  const ext = globalThis.browser ?? globalThis.chrome;
  if (!ext?.runtime?.getURL) return;

  try {
    const script = document.createElement('script');
    script.src = ext.runtime.getURL('page-bridge.js');
    script.async = false;
    script.onload = () => script.remove();
    script.onerror = () => script.remove();
    (document.documentElement || document.head || document.body)?.appendChild(script);
  } catch {
    // ignore DOM injection errors on restricted pages
  }
})();
