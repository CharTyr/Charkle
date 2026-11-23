import React, { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { OBJLoader } from 'three/examples/jsm/loaders/OBJLoader.js';
import { STLLoader } from 'three/examples/jsm/loaders/STLLoader.js';
import { Box, Grid, RotateCcw } from 'lucide-react';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';

export interface Model3DViewerProps {
  asset: AssetRecord;
}

const SUPPORTED_WEBGL_EXTS = new Set(['glb', 'gltf', 'obj', 'stl']);

export const Model3DViewer: React.FC<Model3DViewerProps> = ({ asset }) => {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const resetFnRef = useRef<(() => void) | null>(null);
  const loadedGroupRef = useRef<THREE.Object3D | null>(null);

  const ext = (asset.richMetadata?.model3DFormat || asset.fileName.split('.').pop() || '3D')
    .toLowerCase()
    .replace(/^\./, '');
  const webglSupported = SUPPORTED_WEBGL_EXTS.has(ext);

  const [loading, setLoading] = useState(webglSupported);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [wireframe, setWireframe] = useState(false);

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
      setErrorMsg('当前浏览器环境不支持 3D 渲染');
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
    controls.dampingFactor = 0.07;

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

      resetFnRef.current = () => {
        camera.position.copy(fitPos);
        controls.target.set(0, 0, 0);
        controls.update();
      };
    };

    const url = apiClient.originalMediaURL(asset.id);

    const onLoaded = (obj: THREE.Object3D) => {
      if (disposed) return;
      loadedGroupRef.current = obj;
      fitAndCenter(obj);
      scene.add(obj);
      setLoading(false);
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
      if (!host) return;
      const w = host.clientWidth || width;
      const h = host.clientHeight || height;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    });
    ro.observe(host);

    let rafID = 0;
    const animate = () => {
      rafID = requestAnimationFrame(animate);
      controls.update();
      renderer.render(scene, camera);
    };
    animate();

    return () => {
      disposed = true;
      loadedGroupRef.current = null;
      resetFnRef.current = null;
      cancelAnimationFrame(rafID);
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
            {errorMsg || `${ext.toUpperCase()} 格式暂不支持浏览器直接交互渲染，可下载原文件查看`}
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
                ? 'bg-[#2A60E0] border-[#5B8DEF] text-white'
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

      {loading && (
        <div className="absolute inset-0 flex items-center justify-center bg-[#181A20]/75 text-white text-[13px] gap-2">
          <span className="h-4 w-4 rounded-full border-2 border-[#5B8DEF] border-t-transparent animate-spin" />
          正在载入 3D 几何体…
        </div>
      )}
    </div>
  );
};
