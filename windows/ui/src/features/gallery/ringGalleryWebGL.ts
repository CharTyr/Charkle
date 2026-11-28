import { getTransport } from '../../api/transport';
import type { AssetRecord } from '../../types/domain';
import {
  adaptiveCardScale,
  areRingParamsEqual,
  clamp,
  DEFAULT_RING_GALLERY_PARAMS,
  positiveMod,
  releaseGlide,
  RingCardTrack,
  RingCubicBezier,
  ringCurvature,
  ringEffectiveAspectRatio,
  ringProjectedCardContains,
  ringRadius,
  ringStep,
  verticalCenterBias,
  visibleOutsideCards,
  type RingGalleryParameters,
  type RingProjectedCard,
} from './ringGalleryMath';

// ---------------------------------------------------------------------------
// WebGL2 GLSL ES 3.00 Shaders (1:1 port of macOS RingGalleryMetalView.swift)
// 96-column curved strip + superellipse-4 SDF + zero-shimmer mipmap DoF
// ---------------------------------------------------------------------------

const RING_VERTEX_SHADER = `#version 300 es
precision highp float;

uniform vec4 u_geom0;   // x: arcS, y: curvatureC, z: perspectiveP, w: cardWidth
uniform vec4 u_geom1;   // x: cardHeight, y: cornerRadius, z: pressScale, w: radiusR
uniform vec4 u_screen0; // x: minSX, y: maxSX, z: blurPad, w: depthBlurMax
uniform vec4 u_screen1; // x: farFadeMax, y: halfViewportW, z: halfViewportH, w: dpr
uniform vec4 u_media;   // x: imageAspect, y: hasTexture, z: flipTexX, w: uMin
uniform vec4 u_slice;   // x: uMax, y: isFarSide, z: verticalOffsetPt, w: cardScale

out vec2 v_screenPos;
out vec2 v_localPos;
out float v_cardHalfH;
out float v_worldZ;

void main() {
  // 96 interior vertical columns + 1 margin column on each side = 99 stations (198 vertices)
  const int kInteriorSegments = 96;
  int vid = gl_VertexID;
  int col = vid / 2;
  float isTop = (vid % 2 == 0) ? 1.0 : -1.0;

  float pressScale = u_geom1.z;
  float cardH = u_geom1.x;
  float uMin = u_media.w * pressScale;
  float uMax = u_slice.x * pressScale;
  float pad = u_screen0.z;
  float cardScale = u_slice.w;

  float colT = clamp((float(col) - 1.0) / float(kInteriorSegments), 0.0, 1.0);
  float uArc = mix(uMin, uMax, colT);

  float sCol = u_geom0.x + uArc;
  float c = u_geom0.y;
  float a = sCol * c;
  float x = (abs(c) < 1e-6) ? sCol : (sin(a) / c);
  float z = (abs(c) < 1e-6) ? 0.0  : ((1.0 - cos(a)) / c);

  float P = u_geom0.z;
  float depth = max(140.0, P - z);
  float proj = (P / depth) * cardScale;

  float sx = x * proj;
  float halfScreenH = (cardH * 0.5 * pressScale) * proj;

  // Extrude outer margin columns in screen space so blurred edges always have full room
  float dir = (u_slice.y > 0.5) ? -1.0 : 1.0;
  float localX = uArc / max(1e-4, pressScale);
  float cosSlope = max(0.08, abs(cos(a)));

  if (col == 0) {
    sx -= dir * pad;
    localX -= pad / max(1e-4, cosSlope * proj * pressScale);
  } else if (col == kInteriorSegments + 2) {
    sx += dir * pad;
    localX += pad / max(1e-4, cosSlope * proj * pressScale);
  }

  float syRel = isTop * (halfScreenH + pad);
  float sy = syRel + u_slice.z;
  float localY = isTop * (cardH * 0.5 + pad / max(1e-4, proj * pressScale));

  gl_Position = vec4(sx / max(1.0, u_screen1.y), sy / max(1.0, u_screen1.z), 0.0, 1.0);
  v_screenPos = vec2(sx, syRel);
  v_localPos = vec2(localX, localY);
  v_cardHalfH = halfScreenH;
  v_worldZ = z;
}
`;

const RING_FRAGMENT_SHADER = `#version 300 es
precision highp float;

uniform vec4 u_geom0;   // x: arcS, y: curvatureC, z: perspectiveP, w: cardWidth
uniform vec4 u_geom1;   // x: cardHeight, y: cornerRadius, z: pressScale, w: radiusR
uniform vec4 u_screen0; // x: minSX, y: maxSX, z: blurPad, w: depthBlurMax
uniform vec4 u_screen1; // x: farFadeMax, y: halfViewportW, z: halfViewportH, w: dpr
uniform vec4 u_media;   // x: imageAspect, y: hasTexture, z: flipTexX, w: uMin
uniform vec4 u_bgColor;
uniform vec4 u_tintColor;
uniform vec4 u_extra;   // x: sharpHalfPt, y: seamAlpha, z: 0, w: 0

uniform sampler2D u_cardTex;

in vec2 v_screenPos;
in vec2 v_localPos;
in float v_cardHalfH;
in float v_worldZ;

out vec4 fragColor;

void main() {
  // 1. Per-pixel depth-of-field blur radius (screen points), adapting sharp inner zone to front card width
  float halfW = max(120.0, u_screen1.y);
  float sharpHalf = max(48.0, min(halfW - 12.0, u_extra.x));
  float back = clamp(-v_worldZ / (2.0 * max(1.0, u_geom1.w)), 0.0, 1.0);
  float sideBlur = u_screen0.w * pow(smoothstep(sharpHalf, halfW, abs(v_screenPos.x)), 1.4);
  float depthBlur = u_screen0.w * pow(smoothstep(0.25, 0.8, back), 1.2);
  float b = max(sideBlur, depthBlur);
  float bEff = max(b, 0.75);

  // 2. Analytical screen-space box blur edge coverage (thin cards fade naturally, never shimmer)
  float dl = v_screenPos.x - u_screen0.x;
  float dr = u_screen0.y - v_screenPos.x;
  float dt = v_cardHalfH - v_screenPos.y;
  float db = v_screenPos.y + v_cardHalfH;

  float across = clamp((min(dl, bEff) + min(dr, bEff)) / (2.0 * bEff), 0.0, 1.0);
  float down   = clamp((min(dt, bEff) + min(db, bEff)) / (2.0 * bEff), 0.0, 1.0);
  float boxAlpha = smoothstep(0.0, 1.0, across) * smoothstep(0.0, 1.0, down);

  // 3. Superellipse exponent-4 continuous corner SDF softened by exact screen-space blur bEff
  vec2 halfCard = vec2(u_geom0.w * 0.5, u_geom1.x * 0.5);
  float r = min(u_geom1.y, min(halfCard.x, halfCard.y));
  vec2 d = abs(v_localPos) - halfCard + r;
  vec2 m = max(d, vec2(0.0));
  float distLocal = pow(pow(m.x, 4.0) + pow(m.y, 4.0), 0.25) + min(max(d.x, d.y), 0.0) - r;

  float gradPerPoint = max(1e-4, length(vec2(dFdx(distLocal), dFdy(distLocal))) * u_screen1.w);
  float distScreenPt = distLocal / gradPerPoint;
  float cornerAlpha = smoothstep(bEff, -bEff, distScreenPt);

  float alpha = min(boxAlpha, cornerAlpha) * u_extra.y;
  if (alpha < 0.002) {
    discard;
  }

  // 4. Aspect-fill (cover) UV + hardware mipmap blur proportional to b * texelsPerScreenPoint
  vec2 uv = vec2(
    clamp(v_localPos.x / u_geom0.w + 0.5, 0.0, 1.0),
    clamp(0.5 - v_localPos.y / u_geom1.x, 0.0, 1.0)
  );
  if (u_media.z > 0.5) {
    uv.x = 1.0 - uv.x;
  }

  float cardAspect = u_geom0.w / u_geom1.x;
  float imgAspect = max(0.05, u_media.x);
  vec2 coverUV = uv;
  if (imgAspect > cardAspect) {
    float scaleX = cardAspect / imgAspect;
    coverUV.x = (uv.x - 0.5) * scaleX + 0.5;
  } else {
    float scaleY = imgAspect / cardAspect;
    coverUV.y = (uv.y - 0.5) * scaleY + 0.5;
  }

  vec3 rgb;
  if (u_media.y > 0.5) {
    vec2 texSize = vec2(textureSize(u_cardTex, 0));
    vec2 dUVdx = dFdx(coverUV) * texSize * u_screen1.w;
    vec2 dUVdy = dFdy(coverUV) * texSize * u_screen1.w;
    float texelsPerPoint = max(length(dUVdx), length(dUVdy));
    float baseLod = log2(max(1.0, texelsPerPoint / max(1.0, u_screen1.w)));
    float blurLod = log2(max(1.0, b * texelsPerPoint * 0.92));
    float lod = max(baseLod, blurLod);
    rgb = textureLod(u_cardTex, coverUV, lod).rgb;
  } else {
    rgb = u_tintColor.rgb;
  }

  // 5. Far-side fade cleanly toward the current Light/Dark sRGB page ground
  float fadeAmt = u_screen1.x * smoothstep(0.3, 1.0, back);
  rgb = mix(rgb, u_bgColor.rgb, fadeAmt);

  fragColor = vec4(rgb * alpha, alpha);
}
`;

// ---------------------------------------------------------------------------
// Bounded 48-Slot LRU Mipmapped Texture Pool (Purged Cleanly on Unmount)
// ---------------------------------------------------------------------------

interface RingTextureEntry {
  texture: WebGLTexture;
  aspect: number;
  versionKey: string;
  lastUsedTick: number;
}

const MAX_TEXTURE_SLOTS = 48;
const MAX_TEXTURE_SIDE = 768;

export function appendCacheBust(
  url: string,
  updatedAt: string | number | null | undefined,
): string {
  if (!updatedAt || url.startsWith('data:') || url.startsWith('blob:')) return url;
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(updatedAt))}`;
}

function placeholderTint(asset: AssetRecord, isDark: boolean): [number, number, number, number] {
  const hex = asset.dominantColors[0]?.hex;
  if (hex) {
    const cleaned = hex.replace(/[^0-9a-fA-F]/g, '');
    if (cleaned.length === 6) {
      const val = Number.parseInt(cleaned, 16);
      const r = ((val >> 16) & 0xff) / 255;
      const g = ((val >> 8) & 0xff) / 255;
      const b = (val & 0xff) / 255;
      const base = isDark ? 0.16 : 0.88;
      return [base * 0.72 + r * 0.28, base * 0.72 + g * 0.28, base * 0.72 + b * 0.28, 1.0];
    }
  }
  return isDark ? [0.16, 0.17, 0.2, 1.0] : [0.9, 0.9, 0.88, 1.0];
}

class RingWebGLTexturePool {
  private entries = new Map<string, RingTextureEntry>();
  private inflight = new Map<string, number>();
  private tick = 0;
  private disposed = false;
  private generation = 0;

  constructor(
    private readonly gl: WebGL2RenderingContext,
    private readonly onTextureReady: (assetId: string, aspect: number) => void,
  ) {}

  getTexture(asset: AssetRecord): { texture: WebGLTexture; aspect: number } | null {
    const versionKey = `${asset.id}:${asset.updatedAt}`;
    this.tick += 1;
    const hit = this.entries.get(asset.id);
    if (hit && hit.versionKey === versionKey) {
      hit.lastUsedTick = this.tick;
      return { texture: hit.texture, aspect: hit.aspect };
    }
    this.requestLoad(asset, versionKey);
    return hit ? { texture: hit.texture, aspect: hit.aspect } : null;
  }

  prefetch(assets: readonly AssetRecord[]): void {
    for (const asset of assets) {
      const versionKey = `${asset.id}:${asset.updatedAt}`;
      const hit = this.entries.get(asset.id);
      if (hit && hit.versionKey === versionKey) continue;
      this.requestLoad(asset, versionKey);
    }
  }

  purgeAll(): void {
    this.disposed = true;
    this.generation += 1;
    this.inflight.clear();
    for (const entry of this.entries.values()) {
      this.gl.deleteTexture(entry.texture);
    }
    this.entries.clear();
  }

  private requestLoad(asset: AssetRecord, versionKey: string): void {
    if (this.disposed) return;
    const existingGen = this.inflight.get(versionKey);
    if (existingGen !== undefined) return;

    const myGen = ++this.generation;
    this.inflight.set(versionKey, myGen);

    const transport = getTransport();
    const primaryUrl = appendCacheBust(transport.thumbnailUrl(asset.id, 'preview1400'), asset.updatedAt);
    const fallbackUrl = appendCacheBust(transport.thumbnailUrl(asset.id, 'grid520'), asset.updatedAt);

    const loadImg = (url: string): Promise<HTMLImageElement | null> =>
      new Promise((resolve) => {
        const img = new Image();
        if (!url.startsWith('data:') && !url.startsWith('blob:')) {
          img.crossOrigin = 'anonymous';
        }
        img.decoding = 'async';
        img.onload = () => resolve(img.naturalWidth > 0 && img.naturalHeight > 0 ? img : null);
        img.onerror = () => resolve(null);
        img.src = url;
      });

    void (async () => {
      let img = await loadImg(primaryUrl);
      if (!img && !this.disposed) {
        img = await loadImg(fallbackUrl);
      }
      this.inflight.delete(versionKey);
      if (this.disposed || !img) return;
      const uploadedAspect = this.uploadImage(asset.id, versionKey, img);
      if (uploadedAspect !== null) {
        this.onTextureReady(asset.id, uploadedAspect);
      }
    })();
  }

  private uploadImage(assetId: string, versionKey: string, img: HTMLImageElement): number | null {
    const gl = this.gl;
    if (gl.isContextLost()) return null;

    const srcW = Math.max(1, img.naturalWidth);
    const srcH = Math.max(1, img.naturalHeight);
    const aspect = srcW / srcH;

    const scale = Math.min(1.0, MAX_TEXTURE_SIDE / Math.max(srcW, srcH));
    const dstW = Math.max(2, Math.round(srcW * scale));
    const dstH = Math.max(2, Math.round(srcH * scale));

    let source: TexImageSource = img;
    if (scale < 0.999 && typeof document !== 'undefined') {
      const off = document.createElement('canvas');
      off.width = dstW;
      off.height = dstH;
      const ctx = off.getContext('2d');
      if (ctx) {
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(img, 0, 0, dstW, dstH);
        source = off;
      }
    }

    const tex = gl.createTexture();
    if (!tex) return null;

    try {
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, 0);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.bindTexture(gl.TEXTURE_2D, null);
    } catch {
      gl.deleteTexture(tex);
      return null;
    }

    const old = this.entries.get(assetId);
    if (old) {
      gl.deleteTexture(old.texture);
    }

    this.tick += 1;
    this.entries.set(assetId, {
      texture: tex,
      aspect,
      versionKey,
      lastUsedTick: this.tick,
    });
    this.evictIfNeeded();
    return aspect;
  }

  private evictIfNeeded(): void {
    if (this.entries.size <= MAX_TEXTURE_SLOTS) return;
    const sorted = Array.from(this.entries.entries()).sort(
      (a, b) => a[1].lastUsedTick - b[1].lastUsedTick,
    );
    const excess = this.entries.size - MAX_TEXTURE_SLOTS;
    for (let i = 0; i < excess; i++) {
      const [id, entry] = sorted[i];
      this.gl.deleteTexture(entry.texture);
      this.entries.delete(id);
    }
  }
}

// ---------------------------------------------------------------------------
// Imperative Demand-Driven WebGL2 Ring Renderer & Physics Engine
// ---------------------------------------------------------------------------

export interface RingEngineCallbacks {
  onFrontAssetChanged: (asset: AssetRecord | null) => void;
  onOpenAsset: (asset: AssetRecord) => void;
  onContextMenuRequest: (asset: AssetRecord, clientX: number, clientY: number) => void;
  onFallbackProjected?: (cards: RingProjectedCard[], cardScale: number, verticalBias: number) => void;
}

export interface RingEngineConfig {
  assets: readonly AssetRecord[];
  selectedAssetId: string | null;
  params: RingGalleryParameters;
  isDarkMode: boolean;
  reduceMotion: boolean;
  topSafeInset: number;
  callbacks: RingEngineCallbacks;
}

interface OffsetAnim {
  from: number;
  to: number;
  startTime: number;
  duration: number;
  curve: RingCubicBezier;
}

interface PressAnim {
  virtualIndex: number;
  fromScale: number;
  toScale: number;
  startTime: number;
  duration: number;
  curve: RingCubicBezier;
}

interface UniformLocations {
  geom0: WebGLUniformLocation | null;
  geom1: WebGLUniformLocation | null;
  screen0: WebGLUniformLocation | null;
  screen1: WebGLUniformLocation | null;
  media: WebGLUniformLocation | null;
  slice: WebGLUniformLocation | null;
  bgColor: WebGLUniformLocation | null;
  tintColor: WebGLUniformLocation | null;
  extra: WebGLUniformLocation | null;
  cardTex: WebGLUniformLocation | null;
}

function compileShader(
  gl: WebGL2RenderingContext,
  type: number,
  source: string,
): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    gl.deleteShader(shader);
    return null;
  }
  return shader;
}

export class RingGalleryWebGLEngine {
  readonly isWebGL2: boolean;

  private readonly gl: WebGL2RenderingContext | null = null;
  private program: WebGLProgram | null = null;
  private vao: WebGLVertexArrayObject | null = null;
  private fallbackTex: WebGLTexture | null = null;
  private uniforms: UniformLocations | null = null;
  private texturePool: RingWebGLTexturePool | null = null;

  private assets: readonly AssetRecord[] = [];
  private params: RingGalleryParameters = { ...DEFAULT_RING_GALLERY_PARAMS };
  private isDarkMode = false;
  private reduceMotion = false;
  private topSafeInset = 68;
  private callbacks: RingEngineCallbacks | null = null;

  private viewportW = 800;
  private viewportH = 520;
  private dpr = 1;

  private offset = 0;
  private cardTrack = new RingCardTrack([], 300, 18);
  private decodedAspects = new Map<string, number>();
  private lastReportedFrontAssetId: string | null = null;

  private offsetAnim: OffsetAnim | null = null;
  private pressAnim: PressAnim | null = null;
  private pressedVirtualIndex: number | null = null;

  private isDragging = false;
  private dragStartX = 0;
  private dragLastX = 0;
  private dragStartOffset = 0;
  private dragMovedTotal = 0;
  private velocitySamples: Array<{ time: number; x: number }> = [];
  private lastClickVirtualIndex: number | null = null;
  private lastClickTime = 0;

  private scrollSnapTimer: number | null = null;
  private lastProjectedCards: RingProjectedCard[] = [];
  private rafId = 0;
  private needsDraw = false;
  private disposed = false;

  private readonly onContextLost = (e: Event): void => {
    e.preventDefault();
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
      this.rafId = 0;
    }
    this.texturePool?.purgeAll();
    this.texturePool = null;
    this.fallbackTex = null;
    this.vao = null;
    this.program = null;
    this.uniforms = null;
  };

  private readonly onContextRestored = (): void => {
    if (this.disposed || !this.gl) return;
    if (!this.initPipeline(this.gl)) return;
    this.texturePool = this.createTexturePool(this.gl);
    this.prefetchAroundCurrentOffset();
    this.requestFrame();
  };

  private createTexturePool(gl: WebGL2RenderingContext): RingWebGLTexturePool {
    return new RingWebGLTexturePool(gl, (assetId, aspect) => {
      const asset = this.assets.find((a) => a.id === assetId);
      if (asset && (asset.pixelWidth <= 0 || asset.pixelHeight <= 0)) {
        const prev = this.decodedAspects.get(assetId);
        if (prev === undefined || Math.abs(prev - aspect) > 0.01) {
          this.decodedAspects.set(assetId, aspect);
          const prevFrontVirtual = this.cardTrack.isEmpty
            ? 0
            : this.cardTrack.nearestVirtualIndex(this.offset);
          const rebuilt = RingCardTrack.build(this.assets, this.params, this.decodedAspects);
          if (!rebuilt.equals(this.cardTrack)) {
            this.cardTrack = rebuilt;
            if (!this.isDragging && !this.offsetAnim && !this.cardTrack.isEmpty) {
              this.offset = this.cardTrack.centerArcForVirtualIndex(prevFrontVirtual);
            }
          }
        }
      }
      this.requestFrame();
    });
  }

  constructor(private readonly canvas: HTMLCanvasElement) {
    let gl: WebGL2RenderingContext | null = null;
    try {
      gl = canvas.getContext('webgl2', {
        alpha: false,
        antialias: false,
        depth: false,
        stencil: false,
        powerPreference: 'high-performance',
        premultipliedAlpha: true,
        preserveDrawingBuffer: false,
      });
    } catch {
      gl = null;
    }

    if (gl && this.initPipeline(gl)) {
      this.gl = gl;
      this.isWebGL2 = true;
      canvas.addEventListener('webglcontextlost', this.onContextLost, false);
      canvas.addEventListener('webglcontextrestored', this.onContextRestored, false);
      this.texturePool = this.createTexturePool(gl);
    } else {
      this.isWebGL2 = false;
    }
  }

  private initPipeline(gl: WebGL2RenderingContext): boolean {
    const vs = compileShader(gl, gl.VERTEX_SHADER, RING_VERTEX_SHADER);
    const fs = compileShader(gl, gl.FRAGMENT_SHADER, RING_FRAGMENT_SHADER);
    if (!vs || !fs) {
      if (vs) gl.deleteShader(vs);
      if (fs) gl.deleteShader(fs);
      return false;
    }

    const program = gl.createProgram();
    if (!program) {
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return false;
    }

    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    gl.deleteShader(vs);
    gl.deleteShader(fs);

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      gl.deleteProgram(program);
      return false;
    }

    const vao = gl.createVertexArray();
    const fallbackTex = gl.createTexture();
    if (!vao || !fallbackTex) {
      if (vao) gl.deleteVertexArray(vao);
      if (fallbackTex) gl.deleteTexture(fallbackTex);
      gl.deleteProgram(program);
      return false;
    }

    gl.bindTexture(gl.TEXTURE_2D, fallbackTex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA,
      1,
      1,
      0,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      new Uint8Array([235, 235, 232, 255]),
    );
    gl.bindTexture(gl.TEXTURE_2D, null);

    this.program = program;
    this.vao = vao;
    this.fallbackTex = fallbackTex;
    this.uniforms = {
      geom0: gl.getUniformLocation(program, 'u_geom0'),
      geom1: gl.getUniformLocation(program, 'u_geom1'),
      screen0: gl.getUniformLocation(program, 'u_screen0'),
      screen1: gl.getUniformLocation(program, 'u_screen1'),
      media: gl.getUniformLocation(program, 'u_media'),
      slice: gl.getUniformLocation(program, 'u_slice'),
      bgColor: gl.getUniformLocation(program, 'u_bgColor'),
      tintColor: gl.getUniformLocation(program, 'u_tintColor'),
      extra: gl.getUniformLocation(program, 'u_extra'),
      cardTex: gl.getUniformLocation(program, 'u_cardTex'),
    };
    return true;
  }

  dispose(): void {
    this.disposed = true;
    this.canvas.removeEventListener('webglcontextlost', this.onContextLost, false);
    this.canvas.removeEventListener('webglcontextrestored', this.onContextRestored, false);
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
      this.rafId = 0;
    }
    if (this.scrollSnapTimer !== null) {
      window.clearTimeout(this.scrollSnapTimer);
      this.scrollSnapTimer = null;
    }
    this.decodedAspects.clear();
    this.texturePool?.purgeAll();
    this.texturePool = null;
    if (this.gl) {
      if (this.fallbackTex) this.gl.deleteTexture(this.fallbackTex);
      if (this.vao) this.gl.deleteVertexArray(this.vao);
      if (this.program) this.gl.deleteProgram(this.program);
    }
    this.fallbackTex = null;
    this.vao = null;
    this.program = null;
    this.uniforms = null;
  }

  resize(width: number, height: number, dpr = window.devicePixelRatio || 1): void {
    const w = Math.max(1, Math.round(width));
    const h = Math.max(1, Math.round(height));
    const clampedDpr = Math.max(1, Math.min(3, dpr));
    const pixelW = Math.max(1, Math.round(w * clampedDpr));
    const pixelH = Math.max(1, Math.round(h * clampedDpr));
    if (
      w === this.viewportW &&
      h === this.viewportH &&
      clampedDpr === this.dpr &&
      this.canvas.width === pixelW &&
      this.canvas.height === pixelH
    ) {
      return;
    }
    this.viewportW = w;
    this.viewportH = h;
    this.dpr = clampedDpr;
    if (this.canvas.width !== pixelW) this.canvas.width = pixelW;
    if (this.canvas.height !== pixelH) this.canvas.height = pixelH;
    this.requestFrame();
  }

  configure(config: RingEngineConfig): void {
    const listChanged =
      this.assets.length !== config.assets.length ||
      this.assets.some((a, i) => a.id !== config.assets[i]?.id);

    const oldParams = this.params;
    const paramsChanged = !areRingParamsEqual(oldParams, config.params);
    const newTrack = RingCardTrack.build(config.assets, config.params, this.decodedAspects);
    const trackGeometryChanged = !newTrack.equals(this.cardTrack);
    const appearanceChanged =
      this.isDarkMode !== config.isDarkMode ||
      this.topSafeInset !== config.topSafeInset ||
      paramsChanged ||
      trackGeometryChanged;

    const previousFrontVirtual = this.cardTrack.isEmpty
      ? 0
      : this.cardTrack.nearestVirtualIndex(this.offset);

    this.assets = config.assets;
    this.params = { ...config.params };
    this.cardTrack = newTrack;
    this.isDarkMode = config.isDarkMode;
    this.reduceMotion = config.reduceMotion;
    this.topSafeInset = config.topSafeInset;
    this.callbacks = config.callbacks;

    if (listChanged) {
      this.offsetAnim = null;
      if (config.selectedAssetId) {
        const idx = config.assets.findIndex((a) => a.id === config.selectedAssetId);
        this.offset = idx >= 0 ? this.cardTrack.centerArcForVirtualIndex(idx) : 0;
      } else {
        this.offset = 0;
      }
      this.reportFrontAssetIfChanged(true);
      this.prefetchAroundCurrentOffset();
      this.requestFrame();
    } else {
      if (
        trackGeometryChanged &&
        !this.isDragging &&
        !this.offsetAnim &&
        !this.cardTrack.isEmpty
      ) {
        this.offset = this.cardTrack.centerArcForVirtualIndex(previousFrontVirtual);
      }
      if (
        config.selectedAssetId &&
        config.selectedAssetId !== this.lastReportedFrontAssetId &&
        !this.isDragging &&
        !this.offsetAnim
      ) {
        const idx = config.assets.findIndex((a) => a.id === config.selectedAssetId);
        if (idx >= 0) {
          this.rotateToAssetIndex(idx, this.reduceMotion ? 0.18 : 0.76);
        }
      }
    }

    if (paramsChanged) {
      this.offsetAnim = null;
      this.requestFrame();
    } else if (appearanceChanged) {
      this.requestFrame();
    }
  }

  step(delta: number): void {
    if (this.assets.length === 0 || this.cardTrack.isEmpty) return;
    const baseIdx = this.offsetAnim
      ? this.cardTrack.nearestVirtualIndex(this.offsetAnim.to)
      : this.cardTrack.nearestVirtualIndex(this.offset);
    let targetIdx = baseIdx + delta;
    if (this.assets.length <= 3) {
      targetIdx = Math.max(0, Math.min(this.assets.length - 1, targetIdx));
    }
    const targetOffset = this.cardTrack.centerArcForVirtualIndex(targetIdx);
    this.startOffsetAnimation(targetOffset, this.reduceMotion ? 0.16 : 0.56);
  }

  selectVirtualIndex(vIdx: number): void {
    if (this.cardTrack.isEmpty) return;
    this.startOffsetAnimation(
      this.cardTrack.centerArcForVirtualIndex(vIdx),
      this.reduceMotion ? 0.18 : 0.76,
    );
  }

  private rotateToAssetIndex(targetAssetIdx: number, duration: number): void {
    if (this.assets.length === 0 || this.cardTrack.isEmpty) return;
    const currentVirtual = this.cardTrack.nearestVirtualIndex(this.offset);
    const currentAsset = positiveMod(currentVirtual, this.assets.length);
    let delta = targetAssetIdx - currentAsset;
    if (this.assets.length > 3) {
      const half = Math.floor(this.assets.length / 2);
      if (delta > half) delta -= this.assets.length;
      if (delta < -half) delta += this.assets.length;
    }
    const targetVirtual = currentVirtual + delta;
    this.startOffsetAnimation(
      this.cardTrack.centerArcForVirtualIndex(targetVirtual),
      duration,
    );
  }

  private currentLayoutMetrics(): { cardScale: number; verticalBiasPt: number } {
    const cardScale = adaptiveCardScale(
      this.viewportW,
      this.viewportH,
      this.topSafeInset,
      72.0,
      this.params,
    );
    const verticalBiasPt = verticalCenterBias(this.topSafeInset, 72.0);
    return { cardScale, verticalBiasPt };
  }

  private screenCoordinates(clientX: number, clientY: number): { sx: number; sy: number } {
    const rect = this.canvas.getBoundingClientRect();
    const localX = clientX - rect.left;
    const localY = clientY - rect.top;
    const { verticalBiasPt } = this.currentLayoutMetrics();
    const sx = localX - rect.width * 0.5;
    // DOM clientY grows downward; Ring math Y grows upward
    const sy = rect.height * 0.5 - localY - verticalBiasPt;
    return { sx, sy };
  }

  hitTest(clientX: number, clientY: number): RingProjectedCard | null {
    const { sx, sy } = this.screenCoordinates(clientX, clientY);
    for (let i = this.lastProjectedCards.length - 1; i >= 0; i--) {
      const card = this.lastProjectedCards[i];
      if (ringProjectedCardContains(card, sx, sy)) {
        return card;
      }
    }
    return null;
  }

  handlePointerDown(clientX: number, clientY: number): void {
    this.offsetAnim = null;
    if (this.scrollSnapTimer !== null) {
      window.clearTimeout(this.scrollSnapTimer);
      this.scrollSnapTimer = null;
    }

    this.isDragging = true;
    this.dragStartX = clientX;
    this.dragLastX = clientX;
    this.dragStartOffset = this.offset;
    this.dragMovedTotal = 0;
    const now = performance.now() * 0.001;
    this.velocitySamples = [{ time: now, x: clientX }];

    const hit = this.hitTest(clientX, clientY);
    if (hit) {
      this.pressedVirtualIndex = hit.virtualIndex;
      this.startPressAnimation(hit.virtualIndex, 0.95, 0.14, RingCubicBezier.pressIn);
    } else {
      this.pressedVirtualIndex = null;
    }
  }

  handlePointerMove(clientX: number): void {
    if (!this.isDragging) return;
    const dx = clientX - this.dragLastX;
    this.dragLastX = clientX;
    this.dragMovedTotal += Math.abs(dx);

    if (this.dragMovedTotal > 4 && this.pressedVirtualIndex !== null) {
      const pv = this.pressedVirtualIndex;
      this.pressedVirtualIndex = null;
      this.startPressAnimation(pv, 1.0, 0.32, RingCubicBezier.pressOut);
    }

    const { cardScale } = this.currentLayoutMetrics();
    const arcDelta = (clientX - this.dragStartX) / Math.max(0.25, cardScale);
    this.offset = this.dragStartOffset - arcDelta;

    if (this.assets.length <= 3 && !this.cardTrack.isEmpty) {
      const step = ringStep(this.params);
      const maxOff = this.cardTrack.centerArcForVirtualIndex(Math.max(0, this.assets.length - 1));
      this.offset = clamp(this.offset, -step * 0.35, maxOff + step * 0.35);
    }

    const now = performance.now() * 0.001;
    this.velocitySamples.push({ time: now, x: clientX });
    this.velocitySamples = this.velocitySamples.filter((s) => now - s.time <= 0.11);

    this.reportFrontAssetIfChanged(false);
    this.prefetchAroundCurrentOffset();
    this.requestFrame();
  }

  handlePointerUp(clientX: number, clientY: number, detailClickCount = 1): void {
    if (!this.isDragging) return;
    this.isDragging = false;

    const releasedPressed = this.pressedVirtualIndex;
    this.pressedVirtualIndex = null;
    if (releasedPressed !== null) {
      this.startPressAnimation(releasedPressed, 1.0, 0.32, RingCubicBezier.pressOut);
    }

    const now = performance.now() * 0.001;

    if (this.dragMovedTotal < 5) {
      const hit = this.hitTest(clientX, clientY);
      if (hit && !this.cardTrack.isEmpty) {
        const frontVirtual = this.cardTrack.nearestVirtualIndex(this.offset);
        const isDouble =
          detailClickCount >= 2 ||
          (this.lastClickVirtualIndex === hit.virtualIndex && now - this.lastClickTime < 0.38);
        this.lastClickVirtualIndex = hit.virtualIndex;
        this.lastClickTime = now;

        if (hit.virtualIndex === frontVirtual) {
          if (isDouble && hit.assetIndex < this.assets.length) {
            this.callbacks?.onOpenAsset(this.assets[hit.assetIndex]);
          } else {
            this.startOffsetAnimation(
              this.cardTrack.centerArcForVirtualIndex(frontVirtual),
              0.32,
            );
          }
        } else {
          this.startOffsetAnimation(
            this.cardTrack.centerArcForVirtualIndex(hit.virtualIndex),
            0.76,
          );
        }
      } else if (!this.cardTrack.isEmpty) {
        const snappedIdx = this.cardTrack.nearestVirtualIndex(this.offset);
        this.startOffsetAnimation(this.cardTrack.centerArcForVirtualIndex(snappedIdx), 0.42);
      }
      return;
    }

    const { cardScale } = this.currentLayoutMetrics();
    let velocityScreen = 0;
    const first = this.velocitySamples.find((s) => now - s.time <= 0.1);
    const last = this.velocitySamples[this.velocitySamples.length - 1];
    if (first && last && last.time - first.time > 0.005) {
      velocityScreen = (last.x - first.x) / (last.time - first.time);
    }
    this.velocitySamples = [];
    const velocityArc = velocityScreen / Math.max(0.25, cardScale);

    let { targetOffset, duration } = releaseGlide(
      this.offset,
      velocityArc,
      this.cardTrack,
      this.reduceMotion,
    );
    if (this.assets.length <= 3 && !this.cardTrack.isEmpty) {
      const maxOff = this.cardTrack.centerArcForVirtualIndex(Math.max(0, this.assets.length - 1));
      targetOffset = clamp(targetOffset, 0, maxOff);
    }
    this.startOffsetAnimation(targetOffset, duration);
  }

  handleWheel(deltaX: number, deltaY: number, deltaMode: number): void {
    if (this.assets.length === 0) return;
    this.offsetAnim = null;
    if (this.scrollSnapTimer !== null) {
      window.clearTimeout(this.scrollSnapTimer);
      this.scrollSnapTimer = null;
    }

    const { cardScale } = this.currentLayoutMetrics();
    const rawDelta = Math.abs(deltaX) > Math.abs(deltaY) ? deltaX : deltaY;
    const scale = deltaMode === 0 ? 1.05 : 22.0;
    this.offset += (rawDelta * scale) / Math.max(0.35, cardScale);

    if (this.assets.length <= 3 && !this.cardTrack.isEmpty) {
      const step = ringStep(this.params);
      const maxOff = this.cardTrack.centerArcForVirtualIndex(Math.max(0, this.assets.length - 1));
      this.offset = clamp(this.offset, -step * 0.25, maxOff + step * 0.25);
    }

    this.reportFrontAssetIfChanged(false);
    this.prefetchAroundCurrentOffset();
    this.requestFrame();

    this.scrollSnapTimer = window.setTimeout(() => {
      this.scrollSnapTimer = null;
      if (this.disposed || this.isDragging || this.cardTrack.isEmpty) return;
      const snapIdx = this.cardTrack.nearestVirtualIndex(this.offset);
      const snapped = this.cardTrack.centerArcForVirtualIndex(snapIdx);
      if (Math.abs(snapped - this.offset) > 0.4) {
        this.startOffsetAnimation(snapped, this.reduceMotion ? 0.15 : 0.42);
      }
    }, 150);
  }

  handleContextMenu(clientX: number, clientY: number): boolean {
    const hit = this.hitTest(clientX, clientY);
    if (!hit || hit.assetIndex >= this.assets.length) return false;
    this.callbacks?.onContextMenuRequest(this.assets[hit.assetIndex], clientX, clientY);
    return true;
  }

  private startOffsetAnimation(target: number, duration: number): void {
    const clampedDuration = this.reduceMotion ? Math.min(0.2, duration) : duration;
    this.offsetAnim = {
      from: this.offset,
      to: target,
      startTime: performance.now() * 0.001,
      duration: Math.max(0.05, clampedDuration),
      curve: RingCubicBezier.dragGlide,
    };
    this.requestFrame();
  }

  private startPressAnimation(
    virtualIndex: number,
    toScale: number,
    duration: number,
    curve: RingCubicBezier,
  ): void {
    const now = performance.now() * 0.001;
    const current = this.currentPressScale(virtualIndex, now);
    this.pressAnim = {
      virtualIndex,
      fromScale: current,
      toScale,
      startTime: now,
      duration: this.reduceMotion ? 0.05 : duration,
      curve,
    };
    this.requestFrame();
  }

  private currentPressScale(virtualIndex: number, now: number): number {
    const anim = this.pressAnim;
    if (!anim || anim.virtualIndex !== virtualIndex) return 1.0;
    const t = clamp((now - anim.startTime) / Math.max(0.001, anim.duration), 0.0, 1.0);
    const eased = anim.curve.evaluate(t);
    return anim.fromScale + (anim.toScale - anim.fromScale) * eased;
  }

  private reportFrontAssetIfChanged(force: boolean): void {
    if (this.assets.length === 0 || this.cardTrack.isEmpty) {
      if (this.lastReportedFrontAssetId !== null || force) {
        this.lastReportedFrontAssetId = null;
        this.callbacks?.onFrontAssetChanged(null);
      }
      return;
    }
    const vIdx = this.cardTrack.nearestVirtualIndex(this.offset);
    const frontIdx =
      this.assets.length <= 3
        ? Math.max(0, Math.min(this.assets.length - 1, vIdx))
        : positiveMod(vIdx, this.assets.length);
    const asset = this.assets[frontIdx];
    if (force || asset.id !== this.lastReportedFrontAssetId) {
      this.lastReportedFrontAssetId = asset.id;
      this.callbacks?.onFrontAssetChanged(asset);
    }
  }

  private prefetchAroundCurrentOffset(): void {
    if (this.assets.length === 0 || this.cardTrack.isEmpty || !this.texturePool) return;
    const centerVirtual = this.cardTrack.nearestVirtualIndex(this.offset);
    const radiusSlots = Math.min(this.assets.length, Math.floor(this.params.slotCount / 2) + 4);
    const batch: AssetRecord[] = [];
    const seen = new Set<string>();
    for (let d = -radiusSlots; d <= radiusSlots; d++) {
      const idx = positiveMod(centerVirtual + d, this.assets.length);
      const asset = this.assets[idx];
      if (!seen.has(asset.id)) {
        seen.add(asset.id);
        batch.push(asset);
      }
    }
    this.texturePool.prefetch(batch);
  }

  requestFrame(): void {
    if (this.disposed) return;
    this.needsDraw = true;
    if (!this.rafId) {
      this.rafId = requestAnimationFrame(this.frameLoop);
    }
  }

  private readonly frameLoop = (): void => {
    this.rafId = 0;
    if (this.disposed) return;
    this.needsDraw = false;

    const now = performance.now() * 0.001;

    if (this.offsetAnim) {
      const anim = this.offsetAnim;
      const t = clamp((now - anim.startTime) / anim.duration, 0.0, 1.0);
      const eased = anim.curve.evaluate(t);
      this.offset = anim.from + (anim.to - anim.from) * eased;
      if (t >= 1.0) {
        this.offset = anim.to;
        this.offsetAnim = null;
        this.prefetchAroundCurrentOffset();
      }
      this.reportFrontAssetIfChanged(false);
    }

    if (this.pressAnim && now - this.pressAnim.startTime >= this.pressAnim.duration) {
      if (Math.abs(this.pressAnim.toScale - 1.0) < 1e-4) {
        this.pressAnim = null;
      }
    }

    this.drawFrame(now);

    const hasPressAnim =
      this.pressAnim !== null && now - this.pressAnim.startTime < this.pressAnim.duration;
    // Strictly demand-driven: stop rAF immediately once settled so idle GPU/CPU = 0%
    if (this.offsetAnim !== null || hasPressAnim || this.isDragging || this.needsDraw) {
      this.rafId = requestAnimationFrame(this.frameLoop);
    }
  };

  private drawFrame(now: number): void {
    const { cardScale, verticalBiasPt } = this.currentLayoutMetrics();
    const projected = visibleOutsideCards({
      track: this.cardTrack,
      offset: this.offset,
      params: this.params,
      viewportWidth: this.viewportW,
      viewportHeight: this.viewportH,
      cardScale,
      pressScaleForVirtualIndex: (vIdx) => this.currentPressScale(vIdx, now),
    });
    this.lastProjectedCards = projected;

    const gl = this.gl;
    if (!gl || !this.program || !this.vao || !this.uniforms || !this.fallbackTex || gl.isContextLost()) {
      this.callbacks?.onFallbackProjected?.(projected, cardScale, verticalBiasPt);
      return;
    }

    // Exact Light #F6F6F5 / Dark #141517 sRGB page ground
    const bgR = this.isDarkMode ? 0x14 / 255 : 0xf6 / 255;
    const bgG = this.isDarkMode ? 0x15 / 255 : 0xf6 / 255;
    const bgB = this.isDarkMode ? 0x17 / 255 : 0xf5 / 255;

    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.clearColor(bgR, bgG, bgB, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    if (projected.length === 0) return;

    gl.disable(gl.DEPTH_TEST);
    gl.disable(gl.CULL_FACE);
    gl.enable(gl.BLEND);
    gl.blendEquation(gl.FUNC_ADD);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);

    gl.useProgram(this.program);
    gl.bindVertexArray(this.vao);

    const halfW = Math.max(1.0, this.viewportW * 0.5);
    const halfH = Math.max(1.0, this.viewportH * 0.5);
    const effectiveBlur = this.params.depthBlur * clamp(cardScale, 0.72, 1.38);
    const blurPad = effectiveBlur + 4.0;
    const frontCardW = this.cardTrack.interpolatedFrontCardWidth(this.offset);
    const sharpHalfPt = Math.min(halfW * 0.78, Math.max(110.0, frontCardW * 0.54) * cardScale);
    const curvature = ringCurvature(this.params);
    const radius = ringRadius(this.params);

    const u = this.uniforms;
    gl.uniform4f(u.bgColor, bgR, bgG, bgB, 1.0);
    gl.activeTexture(gl.TEXTURE0);
    gl.uniform1i(u.cardTex, 0);

    for (const card of projected) {
      if (card.assetIndex >= this.assets.length) continue;
      const asset = this.assets[card.assetIndex];
      const pScale = this.currentPressScale(card.virtualIndex, now);

      const texHit = this.texturePool?.getTexture(asset) ?? null;
      const activeTex = texHit?.texture ?? this.fallbackTex;
      const imgAspect = texHit?.aspect ?? Math.max(0.2, ringEffectiveAspectRatio(asset));
      const hasTex = texHit ? 1.0 : 0.0;
      const tint = placeholderTint(asset, this.isDarkMode);

      gl.uniform4f(u.geom0, card.arcS, curvature, this.params.perspective, card.cardWidth);
      gl.uniform4f(u.geom1, this.params.cardHeight, this.params.cornerRadius, pScale, radius);
      gl.uniform4f(u.screen0, card.minScreenX, card.maxScreenX, blurPad, effectiveBlur);
      gl.uniform4f(u.screen1, this.params.farFade, halfW, halfH, this.dpr);
      gl.uniform4f(u.media, imgAspect, hasTex, card.isFarSide ? 1.0 : 0.0, card.uMin);
      gl.uniform4f(u.slice, card.uMax, card.isFarSide ? 1.0 : 0.0, verticalBiasPt, cardScale);
      gl.uniform4f(u.tintColor, tint[0], tint[1], tint[2], tint[3]);
      gl.uniform4f(u.extra, sharpHalfPt, card.seamAlpha, 0.0, 0.0);

      gl.bindTexture(gl.TEXTURE_2D, activeTex);
      // 96 interior columns + 2 margin columns = 99 column stations * 2 vertices = 198 vertices
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 198);
    }

    gl.bindTexture(gl.TEXTURE_2D, null);
    gl.bindVertexArray(null);
  }
}
