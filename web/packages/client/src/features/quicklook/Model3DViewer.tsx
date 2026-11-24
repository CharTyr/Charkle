import React, { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { OBJLoader } from 'three/examples/jsm/loaders/OBJLoader.js';
import { STLLoader } from 'three/examples/jsm/loaders/STLLoader.js';
import { Box, Grid, RotateCcw } from 'lucide-react';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { SkeletonBlock, useDelayedFlag } from '../../design-system';

export interface Model3DViewerProps {
  asset: AssetRecord;
}

const SUPPORTED_WEBGL_EXTS = new Set(['glb', 'gltf', 'obj', 'stl']);

/**
 * On-demand WebGL 3D Viewer:
 * Renders ONLY when OrbitControls moves/damps, when the model loads, on resize, or when
 * wireframe/reset toggles — dropping idle GPU/CPU frame usage to 0%.
 */
export const Model3DViewer: React.FC<Model3DViewerProps> = ({ asset }) => {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const resetFnRef = useRef<(() => void) | null>(null);
  const requestRenderRef = useRef<(() => void) | null>(null);
  const loadedGroupRef = useRef<THREE.Object3D | null>(null);

  const ext = (asset.richMetadata?.model3DFormat || asset.fileName.split('.').pop() || '3D')
    .toLowerCase()
    .replace(/^\./, '');
  const webglSupported = SUPPORTED_WEBGL_EXTS.has(ext);

  const [loading, setLoading] = useState(webglSupported);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [wireframe, setWireframe] = useState(false);

  const showLoadingOverlay = useDelayedFlag(loading, 300, 500);

  useEffect(() => {
    const group = loadedGroupRef.current;
    if (!group) return;
    group.traverse((child) => {
      if ((child as THREE.Mesh).isMesh) {
        const mesh = child as THREE.Mesh;
        const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
        for (const mat of mats) {
          if ('wireframe' in mat) {
            (mat as THREE.MeshStandardMaterial).wireframe = wireframe;
          }
        }
      }
    });
    requestRenderRef.current?.();
  }, [wireframe]);

  useEffect(() => {
    if (!webglSupported) return;
    const host = mountRef.current;
    if (!host) return;

    let disposed = false;
    setLoading(true);
    setErrorMsg(null);

    const width = host.clientWidth || 880;
    const height = host.clientHeight || 580;

    let renderer: THREE.WebGLRenderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    } catch {
      setLoading(false);
      setErrorMsg('当前浏览器不支持 3D 预览');
      return;
    }

    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(width, height);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.1;
    host.innerHTML = '';
    host.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    scene.background = new THREE.Color('#181A20');

    const camera = new THREE.PerspectiveCamera(42, width / height, 0.05, 500);
    camera.position.set(2.4, 1.8, 3.2);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;

    // 3-Point Neutral Studio Lighting
    const hemi = new THREE.HemisphereLight(0xffffff, 0x2b303a, 1.1);
    scene.add(hemi);
    const key = new THREE.DirectionalLight(0xfffaf2, 1.5);
    key.position.set(5, 8, 6);
    scene.add(key);
    const rim = new THREE.DirectionalLight(0xa8c5ff, 0.75);
    rim.position.set(-6, 4, -5);
    scene.add(rim);

    // Subtle studio floor grid
    const grid = new THREE.GridHelper(12, 24, 0x333844, 0x242832);
    grid.position.y = -1.0;
    scene.add(grid);

    // On-demand render scheduler: runs frames only during interaction & damping settle
    let rafID = 0;
    let interacting = false;
    let dampingFramesRemaining = 0;
    const prevCamPos = new THREE.Vector3();
    const prevTarget = new THREE.Vector3();

    const renderFrame = () => {
      rafID = 0;
      if (disposed) return;

      prevCamPos.copy(camera.position);
      prevTarget.copy(controls.target);
      controls.update();
      renderer.render(scene, camera);

      const moved =
        camera.position.distanceToSquared(prevCamPos) > 1e-8 ||
        controls.target.distanceToSquared(prevTarget) > 1e-8;

      if (interacting || moved || dampingFramesRemaining > 0) {
        if (!interacting && !moved) {
          dampingFramesRemaining = Math.max(0, dampingFramesRemaining - 1);
        }
        rafID = requestAnimationFrame(renderFrame);
      }
    };

    const scheduleRender = (settleFrames = 0) => {
      if (disposed) return;
      dampingFramesRemaining = Math.max(dampingFramesRemaining, settleFrames);
      if (!rafID) {
        rafID = requestAnimationFrame(renderFrame);
      }
    };
    requestRenderRef.current = () => scheduleRender(0);

    const onControlStart = () => {
      interacting = true;
      scheduleRender(2);
    };
    const onControlEnd = () => {
      interacting = false;
      scheduleRender(24);
    };
    const onControlChange = () => {
      scheduleRender(interacting ? 2 : 12);
    };

    controls.addEventListener('start', onControlStart);
    controls.addEventListener('end', onControlEnd);
    controls.addEventListener('change', onControlChange);

    const fitAndCenter = (obj: THREE.Object3D) => {
      const box = new THREE.Box3().setFromObject(obj);
      const size = box.getSize(new THREE.Vector3());
      const center = box.getCenter(new THREE.Vector3());
      const maxDim = Math.max(size.x, size.y, size.z, 0.001);
      const scale = 2.2 / maxDim;
      obj.scale.setScalar(scale);
      obj.position.sub(center.multiplyScalar(scale));

      const fitPos = new THREE.Vector3(2.4, 1.6, 3.0);
      camera.position.copy(fitPos);
      controls.target.set(0, 0, 0);
      controls.update();
      scheduleRender(0);

      resetFnRef.current = () => {
        camera.position.copy(fitPos);
        controls.target.set(0, 0, 0);
        controls.update();
        scheduleRender(0);
      };
    };

    const url = apiClient.originalMediaURL(asset.id);

    const onLoaded = (obj: THREE.Object3D) => {
      if (disposed) return;
      loadedGroupRef.current = obj;
      fitAndCenter(obj);
      scene.add(obj);
      setLoading(false);
      scheduleRender(0);
    };

    const onError = () => {
      if (disposed) return;
      setLoading(false);
      setErrorMsg(`无法解析 ${ext.toUpperCase()} 模型文件`);
    };

    if (ext === 'glb' || ext === 'gltf') {
      const loader = new GLTFLoader();
      loader.setWithCredentials(true);
      loader.load(url, (gltf) => onLoaded(gltf.scene), undefined, onError);
    } else if (ext === 'obj') {
      const loader = new OBJLoader();
      loader.setWithCredentials(true);
      loader.load(
        url,
        (obj) => {
          obj.traverse((child) => {
            if ((child as THREE.Mesh).isMesh) {
              const m = child as THREE.Mesh;
              if (!m.material) {
                m.material = new THREE.MeshStandardMaterial({
                  color: 0xd8dce4,
                  roughness: 0.45,
                  metalness: 0.15,
                });
              }
            }
          });
          onLoaded(obj);
        },
        undefined,
        onError,
      );
    } else if (ext === 'stl') {
      const loader = new STLLoader();
      loader.setWithCredentials(true);
      loader.load(
        url,
        (geometry) => {
          geometry.computeVertexNormals();
          const mat = new THREE.MeshStandardMaterial({
            color: 0xd4d9e2,
            roughness: 0.4,
            metalness: 0.18,
          });
          const mesh = new THREE.Mesh(geometry, mat);
          onLoaded(mesh);
        },
        undefined,
        onError,
      );
    }

    const ro = new ResizeObserver(() => {
      if (!host || disposed) return;
      const w = host.clientWidth || width;
      const h = host.clientHeight || height;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
      scheduleRender(0);
    });
    ro.observe(host);

    // Render initial empty studio grid once
    scheduleRender(0);

    return () => {
      disposed = true;
      loadedGroupRef.current = null;
      resetFnRef.current = null;
      requestRenderRef.current = null;
      if (rafID) cancelAnimationFrame(rafID);
      controls.removeEventListener('start', onControlStart);
      controls.removeEventListener('end', onControlEnd);
      controls.removeEventListener('change', onControlChange);
      ro.disconnect();
      controls.dispose();
      renderer.dispose();
    };
  }, [asset.id, ext, webglSupported]);

  return (
    <div className="relative w-[min(960px,92vw)] h-[min(640px,76vh)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[#181A20] border border-white/12 shadow-2xl">
      {webglSupported && !errorMsg ? (
        <div ref={mountRef} className="w-full h-full cursor-grab active:cursor-grabbing" />
      ) : (
        <div className="w-full h-full flex flex-col items-center justify-center gap-3 p-8 text-center text-[#D1D5DB]">
          <Box size={44} className="text-[#60A5FA]" />
          <div className="text-[15px] font-semibold text-white">{asset.title}</div>
          <div className="text-[12.5px] text-[#9CA3AF]">
            {errorMsg || `暂不支持预览 ${ext.toUpperCase()} 文件，可下载查看`}
          </div>
          <img
            src={apiClient.thumbnailURL(asset.id, 'preview1400')}
            alt={asset.title}
            className="max-h-[260px] rounded-[10px] object-contain mt-2"
          />
        </div>
      )}

      {/* Studio Overlay Controls */}
      <div className="absolute top-3.5 left-3.5 flex items-center gap-2 pointer-events-none">
        <span className="px-2.5 py-1 rounded-full bg-black/55 backdrop-blur-md text-[11px] font-mono font-semibold text-white border border-white/12">
          {ext.toUpperCase()} · 3D
        </span>
      </div>

      {webglSupported && !errorMsg && (
        <div className="absolute bottom-3.5 right-3.5 flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => setWireframe((v) => !v)}
            className={[
              'charkle-pressable h-8 px-2.5 rounded-[var(--radius-chip)] backdrop-blur-md text-[12px] inline-flex items-center gap-1.5 border cursor-pointer',
              wireframe
                ? 'bg-[var(--accent)] border-[var(--accent)] text-white'
                : 'bg-black/55 border-white/12 text-white/90 hover:bg-black/75',
            ].join(' ')}
          >
            <Grid size={13} />
            线框
          </button>
          <button
            type="button"
            onClick={() => resetFnRef.current?.()}
            className="charkle-pressable h-8 px-2.5 rounded-[var(--radius-chip)] bg-black/55 hover:bg-black/75 backdrop-blur-md text-[12px] text-white/90 inline-flex items-center gap-1.5 border border-white/12 cursor-pointer"
          >
            <RotateCcw size={13} />
            重置视角
          </button>
        </div>
      )}

      {showLoadingOverlay && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-[#181A20]/80 text-white/85 text-[13px]">
          <SkeletonBlock className="h-14 w-14 rounded-2xl bg-white/10" />
          <span>正在加载 3D 模型…</span>
        </div>
      )}
    </div>
  );
};
