import React, { useEffect, useRef, useState } from 'react';
import { Box, RotateCcw } from 'lucide-react';
import { getTransport } from '../../api/transport';
import type { AssetRecord } from '../../types/domain';

export interface Model3DViewerProps {
  asset: AssetRecord;
}

/**
 * Interactive Three.js 3D model Quick Look viewer supporting GLB/GLTF/OBJ/STL.
 */
export const Model3DViewer: React.FC<Model3DViewerProps> = ({ asset }) => {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const resetFnRef = useRef<(() => void) | null>(null);
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading');
  const [errorMsg, setErrorMsg] = useState<string>('');

  useEffect(() => {
    const container = mountRef.current;
    if (!container) return;

    let disposed = false;
    let rafId = 0;
    let renderer: { dispose: () => void; setSize: (w: number, h: number) => void; render: (s: unknown, c: unknown) => void; domElement: HTMLCanvasElement } | null = null;
    let resizeObs: ResizeObserver | null = null;

    setStatus('loading');
    setErrorMsg('');

    const init = async () => {
      try {
        const THREE = await import('three');
        const { OrbitControls } = await import('three/examples/jsm/controls/OrbitControls.js');
        if (disposed) return;

        const width = Math.max(320, container.clientWidth || 640);
        const height = Math.max(240, container.clientHeight || 480);

        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(45, width / height, 0.05, 2000);
        camera.position.set(2.4, 1.8, 3.2);

        const webgl = new THREE.WebGLRenderer({ antialias: true, alpha: true });
        webgl.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
        webgl.setSize(width, height);
        renderer = webgl as unknown as typeof renderer;
        container.innerHTML = '';
        container.appendChild(webgl.domElement);

        // Neutral studio lighting
        const hemi = new THREE.HemisphereLight(0xffffff, 0x3b404c, 1.25);
        scene.add(hemi);
        const keyLight = new THREE.DirectionalLight(0xffffff, 1.15);
        keyLight.position.set(5, 8, 6);
        scene.add(keyLight);
        const fillLight = new THREE.DirectionalLight(0xdbe4ff, 0.5);
        fillLight.position.set(-5, 2, -4);
        scene.add(fillLight);

        const controls = new OrbitControls(camera, webgl.domElement);
        controls.enableDamping = true;
        controls.dampingFactor = 0.08;

        const url = getTransport().originalUrl(asset.id);
        const ext = (
          asset.richMetadata?.model3DFormat ??
          asset.fileName.split('.').pop() ??
          'glb'
        ).toLowerCase();

        let rootObj: import('three').Object3D;
        if (ext === 'obj') {
          const { OBJLoader } = await import('three/examples/jsm/loaders/OBJLoader.js');
          rootObj = await new OBJLoader().loadAsync(url);
        } else if (ext === 'stl') {
          const { STLLoader } = await import('three/examples/jsm/loaders/STLLoader.js');
          const geom = await new STLLoader().loadAsync(url);
          const mat = new THREE.MeshStandardMaterial({
            color: 0xcfd4de,
            roughness: 0.45,
            metalness: 0.15,
          });
          rootObj = new THREE.Mesh(geom, mat);
        } else {
          const { GLTFLoader } = await import('three/examples/jsm/loaders/GLTFLoader.js');
          const gltf = await new GLTFLoader().loadAsync(url);
          rootObj = gltf.scene;
        }

        if (disposed) return;

        // Auto-center & frame model
        const box = new THREE.Box3().setFromObject(rootObj);
        const center = box.getCenter(new THREE.Vector3());
        const size = box.getSize(new THREE.Vector3());
        const maxDim = Math.max(size.x, size.y, size.z, 0.001);
        const normScale = 2.2 / maxDim;
        rootObj.scale.setScalar(normScale);
        rootObj.position.sub(center.multiplyScalar(normScale));
        scene.add(rootObj);

        const resetCamera = () => {
          camera.position.set(2.4, 1.8, 3.2);
          controls.target.set(0, 0, 0);
          controls.update();
        };
        resetFnRef.current = resetCamera;
        resetCamera();

        if (typeof ResizeObserver !== 'undefined') {
          resizeObs = new ResizeObserver(() => {
            if (!container) return;
            const w = Math.max(200, container.clientWidth);
            const h = Math.max(200, container.clientHeight);
            camera.aspect = w / h;
            camera.updateProjectionMatrix();
            webgl.setSize(w, h);
          });
          resizeObs.observe(container);
        }

        setStatus('ready');
        const tick = () => {
          if (disposed) return;
          controls.update();
          webgl.render(scene, camera);
          rafId = requestAnimationFrame(tick);
        };
        tick();
      } catch (err) {
        if (!disposed) {
          setStatus('error');
          setErrorMsg(err instanceof Error ? err.message : '3D 模型加载失败');
        }
      }
    };

    void init();

    return () => {
      disposed = true;
      cancelAnimationFrame(rafId);
      resizeObs?.disconnect();
      renderer?.dispose();
    };
  }, [asset.id, asset.fileName, asset.richMetadata?.model3DFormat]);

  return (
    <div className="relative w-full h-full max-w-[960px] max-h-[78vh] mx-auto rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl">
      <div ref={mountRef} className="w-full h-full min-h-[420px]" />

      {status === 'loading' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 text-[13px] text-[var(--text-secondary)] pointer-events-none">
          <Box size={24} className="text-[var(--accent)] animate-pulse" />
          <span>正在加载 3D 场景…</span>
        </div>
      )}

      {status === 'error' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 p-6 text-center">
          <Box size={28} className="text-[var(--text-tertiary)]" />
          <div className="text-[14px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
          <p className="text-[12px] text-[var(--text-secondary)] max-w-[360px]">
            {errorMsg || '无法初始化 3D 预览，请确认模型格式（GLB / GLTF / OBJ / STL）完整。'}
          </p>
        </div>
      )}

      {status === 'ready' && (
        <button
          type="button"
          onClick={() => resetFnRef.current?.()}
          className="charkle-glass-dark absolute bottom-4 right-4 h-8 px-3 rounded-full inline-flex items-center gap-1.5 text-[12px] cursor-pointer"
        >
          <RotateCcw size={13} />
          重置视角
        </button>
      )}
    </div>
  );
};
