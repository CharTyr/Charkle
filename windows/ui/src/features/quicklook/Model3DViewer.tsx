import React, { useEffect, useRef, useState } from 'react';
import { Box, FolderOpen, RotateCcw } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface Model3DViewerProps {
  asset: AssetRecord;
}

/**
 * Interactive 3D model Quick Look viewer supporting GLB/GLTF/OBJ/STL
 * with top-right format badge & camera reset (1:1 macOS `QuickLookModel3DViewer`).
 */
export const Model3DViewer: React.FC<Model3DViewerProps> = ({ asset }) => {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const resetFnRef = useRef<(() => void) | null>(null);
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading');
  const [errorMsg, setErrorMsg] = useState<string>('');

  const formatLabel = (
    asset.richMetadata?.model3DFormat ??
    asset.fileName.split('.').pop() ??
    '3D'
  ).toUpperCase();

  useEffect(() => {
    const container = mountRef.current;
    if (!container) return;

    let disposed = false;
    let rafId = 0;
    let renderer: {
      dispose: () => void;
      setSize: (w: number, h: number) => void;
      render: (s: unknown, c: unknown) => void;
      domElement: HTMLCanvasElement;
    } | null = null;
    let controlsRef: { dispose: () => void } | null = null;
    let sceneRef: import('three').Scene | null = null;
    let resizeObs: ResizeObserver | null = null;

    const disposeObject3D = (root: import('three').Object3D | null) => {
      if (!root) return;
      root.traverse((obj) => {
        const mesh = obj as {
          geometry?: { dispose?: () => void };
          material?: unknown;
        };
        mesh.geometry?.dispose?.();
        const materials = Array.isArray(mesh.material)
          ? mesh.material
          : mesh.material
            ? [mesh.material]
            : [];
        for (const mat of materials) {
          if (!mat || typeof mat !== 'object') continue;
          const matRec = mat as Record<string, unknown>;
          for (const key of [
            'map',
            'normalMap',
            'roughnessMap',
            'metalnessMap',
            'emissiveMap',
            'aoMap',
            'alphaMap',
            'bumpMap',
            'lightMap',
            'envMap',
          ]) {
            const tex = matRec[key] as { dispose?: () => void } | undefined;
            tex?.dispose?.();
          }
          (matRec as { dispose?: () => void }).dispose?.();
        }
      });
    };

    resetFnRef.current = null;
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
        sceneRef = scene;
        const camera = new THREE.PerspectiveCamera(45, width / height, 0.05, 2000);
        camera.position.set(2.4, 1.8, 3.2);

        const webgl = new THREE.WebGLRenderer({ antialias: true, alpha: true });
        webgl.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
        webgl.setSize(width, height);
        renderer = webgl as unknown as typeof renderer;
        container.innerHTML = '';
        container.appendChild(webgl.domElement);

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
        controlsRef = controls;

        const url = getTransport().originalUrl(asset.id);
        const ext = formatLabel.toLowerCase();

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

        if (disposed) {
          disposeObject3D(rootObj);
          return;
        }

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
            if (!container || disposed) return;
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
          setErrorMsg(err instanceof Error ? err.message : '无法加载 3D 模型');
        }
      }
    };

    void init();

    return () => {
      disposed = true;
      cancelAnimationFrame(rafId);
      resizeObs?.disconnect();
      controlsRef?.dispose();
      controlsRef = null;
      disposeObject3D(sceneRef);
      sceneRef = null;
      renderer?.dispose();
      renderer = null;
      resetFnRef.current = null;
      container.innerHTML = '';
    };
  }, [asset.id, formatLabel]);

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      className="relative w-full h-full max-w-[960px] max-h-[78vh] mx-auto rounded-[18px] overflow-hidden bg-[#181A20] border border-white/10 shadow-[0_24px_60px_rgba(0,0,0,0.48)]"
    >
      <div ref={mountRef} className="w-full h-full min-h-[420px]" />

      {status === 'loading' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 text-[13px] text-white/75 pointer-events-none">
          <Box size={24} className="text-[#5B8DEF] animate-pulse" />
          <span>正在加载 3D 场景…</span>
        </div>
      )}

      {status === 'error' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center">
          <Box size={34} className="text-white/55" />
          <div className="text-[16px] font-semibold text-white">{asset.title}</div>
          <p className="text-[12.5px] text-white/70 max-w-[360px] leading-relaxed">
            {errorMsg || `该 3D 格式（${formatLabel}）暂不支持内嵌预览，可使用默认软件打开。`}
          </p>
          <Button
            variant="primary"
            size="sm"
            onClick={() => void getTransport().revealInExplorer(asset.id)}
          >
            <FolderOpen size={13} />
            在资源管理器中显示
          </Button>
        </div>
      )}

      {status === 'ready' && (
        <div className="absolute top-3.5 right-3.5 flex items-center gap-2">
          <span className="px-2.5 py-1 rounded-full bg-black/55 text-white/90 text-[11px] font-bold charkle-mono">
            3D · {formatLabel}
          </span>
          <button
            type="button"
            onClick={() => resetFnRef.current?.()}
            className="charkle-pressable px-2.5 py-1 rounded-full bg-black/55 hover:bg-black/75 text-white inline-flex items-center gap-1.5 text-[11px] font-semibold cursor-pointer"
          >
            <RotateCcw size={12} />
            <span>重置视角</span>
          </button>
        </div>
      )}
    </div>
  );
};
