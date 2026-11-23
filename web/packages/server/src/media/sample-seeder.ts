import {
  createDefaultAssetRecord,
  createDefaultAutoLayoutConfig,
  createDefaultMoodboardDocument,
  createDefaultSmartFolderRule,
  freezeIntoFreeform,
  labFromHex,
  toSwiftUUID,
  type AssetRecord,
  type BoardNode,
  type FolderRecord,
  type GitHubRepoMetadata,
  type SocialPostMetadata,
  type UUID,
} from '@charkle/shared';
import type { IMediaPipeline } from '../context.js';
import {
  encodeFeaturePrintFloat32,
  type LibraryDatabase,
} from '../db/library-database.js';
import { randomUUID, sha256HexSync, utf8Encode } from '../runtime/web-crypto-utils.js';
import { sniffImageMimeType } from '../runtime/workers-image.js';

interface StudioArtworkSpec {
  title: string;
  fileName: string;
  folderName: string;
  tags: string[];
  rating: number;
  notes: string;
  svg: string;
}

function buildStudioArtworks(): StudioArtworkSpec[] {
  return [
    {
      title: 'Dark Admin Dashboard',
      fileName: 'Dark Admin Dashboard.png',
      folderName: 'UI Inspiration',
      tags: ['dashboard', 'dark-ui', 'analytics', '暗黑仪表盘'],
      rating: 5,
      notes: 'Clean dark obsidian surfaces with electric indigo data series and hairline dividers.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="820" viewBox="0 0 1200 820">
        <rect width="1200" height="820" fill="#0E1015"/>
        <rect x="36" y="36" width="220" height="748" rx="22" fill="#161922"/>
        <rect x="62" y="96" width="168" height="34" rx="10" fill="#5E6AD2"/>
        <rect x="62" y="154" width="168" height="34" rx="10" fill="#222736"/>
        <rect x="62" y="212" width="168" height="34" rx="10" fill="#222736"/>
        <rect x="62" y="270" width="168" height="34" rx="10" fill="#222736"/>
        <text x="296" y="96" fill="#8B93A7" font-family="Helvetica Neue, sans-serif" font-size="16" font-weight="600">REVENUE ANALYTICS</text>
        <text x="296" y="158" fill="#F5F7FA" font-family="Helvetica Neue, sans-serif" font-size="52" font-weight="700">$482,910</text>
        <rect x="296" y="196" width="264" height="112" rx="18" fill="#1A1E2A"/>
        <text x="318" y="232" fill="#7A839B" font-family="Helvetica Neue, sans-serif" font-size="13" font-weight="600">ACTIVE NODES</text>
        <text x="318" y="278" fill="#E6ECF8" font-family="Helvetica Neue, sans-serif" font-size="28" font-weight="700">18 DIRECT</text>
        <rect x="584" y="196" width="264" height="112" rx="18" fill="#1A1E2A"/>
        <text x="606" y="232" fill="#7A839B" font-family="Helvetica Neue, sans-serif" font-size="13" font-weight="600">LATENCY</text>
        <text x="606" y="278" fill="#E6ECF8" font-family="Helvetica Neue, sans-serif" font-size="28" font-weight="700">42 MS</text>
        <rect x="872" y="196" width="264" height="112" rx="18" fill="#1A1E2A"/>
        <text x="894" y="232" fill="#7A839B" font-family="Helvetica Neue, sans-serif" font-size="13" font-weight="600">SYNC RATE</text>
        <text x="894" y="278" fill="#E6ECF8" font-family="Helvetica Neue, sans-serif" font-size="28" font-weight="700">99.98%</text>
        <rect x="296" y="346" width="840" height="438" rx="22" fill="#161922"/>
        ${[120, 175, 140, 230, 290, 255, 320, 275, 340, 305, 355, 330]
          .map(
            (h, i) =>
              `<rect x="${342 + i * 62}" y="${744 - h}" width="38" height="${h}" rx="10" fill="${i >= 8 ? '#5E6AD2' : '#2B3248'}"/>`,
          )
          .join('')}
      </svg>`,
    },
    {
      title: 'Serif Typography Poster — Zurich 2026',
      fileName: 'Serif Typography Poster.png',
      folderName: 'Typography',
      tags: ['serif', 'poster', 'typography', '瑞士排版', '海报'],
      rating: 5,
      notes: 'High-contrast serif display type with asymmetric Swiss grid margins.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="840" height="1180" viewBox="0 0 840 1180">
        <rect width="840" height="1180" fill="#F4EFE6"/>
        <circle cx="570" cy="778" r="220" fill="#D93829"/>
        <rect x="64" y="120" width="712" height="3" fill="#191816"/>
        <text x="64" y="96" fill="#191816" font-family="Helvetica Neue, sans-serif" font-size="18" font-weight="600">KUNSTHALLE ZURICH · ARCHIVE</text>
        <text x="58" y="340" fill="#191816" font-family="Georgia, serif" font-size="168" font-weight="700">SERIF</text>
        <text x="58" y="506" fill="#191816" font-family="Georgia, serif" font-size="168" font-weight="700">FORM</text>
        <text x="64" y="1062" fill="#191816" font-family="Helvetica Neue, sans-serif" font-size="28" font-weight="500">TYPOGRAPHY POSTER</text>
        <text x="64" y="1104" fill="#5C574F" font-family="Helvetica Neue, sans-serif" font-size="18">NOV 2026 — EDITION 04</text>
      </svg>`,
    },
    {
      title: 'Warm Financial Editorial Spread',
      fileName: 'Warm Editorial Spread.png',
      folderName: 'Editorial',
      tags: ['editorial', 'warm', 'magazine', '暖色调', '排版'],
      rating: 4,
      notes: 'Paper cream background with warm amber highlights and structured metrics.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="1160" height="860" viewBox="0 0 1160 860">
        <rect width="1160" height="860" fill="#F7F1E5"/>
        <rect x="56" y="56" width="520" height="748" rx="24" fill="#E7C28D"/>
        <rect x="112" y="210" width="408" height="420" rx="18" fill="#C46A34"/>
        <text x="620" y="128" fill="#8F5E38" font-family="Helvetica Neue, sans-serif" font-size="16" font-weight="600">ISSUE 14 · AUTUMN</text>
        <text x="616" y="232" fill="#261B14" font-family="Georgia, serif" font-size="84" font-weight="700">Tactile</text>
        <text x="616" y="318" fill="#261B14" font-family="Georgia, serif" font-size="84" font-weight="700">Craft</text>
        ${[0, 1, 2, 3, 4]
          .map(
            (i) =>
              `<rect x="620" y="${420 + i * 34}" width="${440 - (i % 2) * 65}" height="14" rx="7" fill="#D8CCB9"/>`,
          )
          .join('')}
        <text x="620" y="768" fill="#7A6655" font-family="Helvetica Neue, sans-serif" font-size="16" font-weight="500">WARM PALETTE · EDITORIAL DESIGN</text>
      </svg>`,
    },
    {
      title: 'Automation Hero Blue',
      fileName: 'Automation Hero Blue.png',
      folderName: 'UI Inspiration',
      tags: ['hero', 'saas', 'blue', 'landing-page', '蓝色'],
      rating: 5,
      notes: 'Deep cobalt radial lighting with crisp white typography and pill CTA.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="760" viewBox="0 0 1280 760">
        <defs>
          <linearGradient id="cb" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stop-color="#0A1638"/>
            <stop offset="100%" stop-color="#1E4CE8"/>
          </linearGradient>
        </defs>
        <rect width="1280" height="760" fill="url(#cb)"/>
        <circle cx="640" cy="660" r="420" fill="#4EA1FF" opacity="0.28"/>
        <rect x="490" y="130" width="300" height="42" rx="21" fill="#FFFFFF" opacity="0.14"/>
        <text x="640" y="157" text-anchor="middle" fill="#D7E8FF" font-family="Helvetica Neue, sans-serif" font-size="16" font-weight="600">CLOUD AUTOMATION 3.0</text>
        <text x="640" y="310" text-anchor="middle" fill="#FFFFFF" font-family="Helvetica Neue, sans-serif" font-size="88" font-weight="700">Ship Faster With</text>
        <text x="640" y="414" text-anchor="middle" fill="#A8CEFF" font-family="Helvetica Neue, sans-serif" font-size="88" font-weight="700">Direct Sync.</text>
        <rect x="470" y="510" width="340" height="74" rx="37" fill="#FFFFFF"/>
        <text x="640" y="556" text-anchor="middle" fill="#0E2469" font-family="Helvetica Neue, sans-serif" font-size="26" font-weight="600">Get Started →</text>
      </svg>`,
    },
    {
      title: 'Bauhaus Form & Rhythm Study',
      fileName: 'Bauhaus Form Study.png',
      folderName: 'Typography',
      tags: ['bauhaus', 'geometric', 'poster', '包豪斯', '几何'],
      rating: 4,
      notes: 'Primary vermilion, ochre, and cobalt shapes balanced on matte charcoal.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="960" height="960" viewBox="0 0 960 960">
        <rect width="960" height="960" fill="#1D1E22"/>
        <rect x="90" y="490" width="380" height="380" fill="#E6A91A"/>
        <circle cx="640" cy="340" r="210" fill="#DC3E2B"/>
        <rect x="470" y="650" width="380" height="220" fill="#2663B8"/>
        <circle cx="280" cy="680" r="105" fill="#F3EEE4"/>
        <text x="96" y="150" fill="#F3EEE4" font-family="Helvetica Neue, sans-serif" font-size="44" font-weight="700">BAUHAUS 1926</text>
      </svg>`,
    },
    {
      title: 'Emerald Mobile Fintech Wallet',
      fileName: 'Emerald Fintech Mobile.png',
      folderName: 'UI Inspiration',
      tags: ['mobile', 'fintech', 'emerald', 'ios', '金融App'],
      rating: 4,
      notes: 'Portrait card hierarchy with translucent emerald card and tabular numbers.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="760" height="1160" viewBox="0 0 760 1160">
        <defs>
          <linearGradient id="em" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stop-color="#10B981"/>
            <stop offset="100%" stop-color="#065F46"/>
          </linearGradient>
        </defs>
        <rect width="760" height="1160" fill="#0B1512"/>
        <rect x="54" y="90" width="652" height="330" rx="34" fill="url(#em)"/>
        <text x="96" y="168" fill="#D1FAE5" font-family="Helvetica Neue, sans-serif" font-size="18" font-weight="600">TOTAL BALANCE</text>
        <text x="94" y="260" fill="#FFFFFF" font-family="Helvetica Neue, sans-serif" font-size="64" font-weight="700">$84,290.50</text>
        <text x="96" y="346" fill="#A7F3D0" font-family="Helvetica Neue, sans-serif" font-size="18" font-weight="500">+12.4% THIS MONTH</text>
        ${[0, 1, 2, 3]
          .map((i) => {
            const y = 490 + i * 134;
            return `<rect x="54" y="${y}" width="652" height="98" rx="22" fill="#13221D"/><circle cx="112" cy="${y + 49}" r="24" fill="${i === 0 ? '#34D399' : '#1E3A30'}"/><rect x="158" y="${y + 30}" width="220" height="14" rx="7" fill="#D8EDE5"/><rect x="158" y="${y + 56}" width="140" height="11" rx="5" fill="#4E6E63"/>`;
          })
          .join('')}
      </svg>`,
    },
    {
      title: 'Monospace Workflow Monitor',
      fileName: 'Monospace Workflow Monitor.png',
      folderName: 'UI Inspiration',
      tags: ['developer', 'terminal', 'dark-ui', 'monospace', '工具'],
      rating: 5,
      notes: 'High-density technical telemetry panel with crisp status pills.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="800" viewBox="0 0 1200 800">
        <rect width="1200" height="800" fill="#111214"/>
        <rect x="42" y="42" width="1116" height="716" rx="20" fill="#191B1F"/>
        <circle cx="84" cy="84" r="8" fill="#FF5F56"/>
        <circle cx="110" cy="84" r="8" fill="#FFBD2E"/>
        <circle cx="136" cy="84" r="8" fill="#27C93F"/>
        <text x="480" y="90" fill="#8E95A2" font-family="Menlo, monospace" font-size="18">charkle — sync engine</text>
        <text x="84" y="190" fill="#E5E7EB" font-family="Menlo, monospace" font-size="24">$ charkle sync --backend drive</text>
        <text x="84" y="264" fill="#34D399" font-family="Menlo, monospace" font-size="24">  [fts5]   pinyin + unicode61 indexed 146 items</text>
        <text x="84" y="338" fill="#93C5FD" font-family="Menlo, monospace" font-size="24">  [crdt]   merged HLC op-log · 0 conflicts</text>
        <text x="84" y="412" fill="#E5E7EB" font-family="Menlo, monospace" font-size="24">$ charkle mcp --stdio</text>
        <text x="84" y="486" fill="#34D399" font-family="Menlo, monospace" font-size="24">  [mcp]    14 tools online · policy readOnly</text>
      </svg>`,
    },
    {
      title: 'Terracotta Studio — Ceramic Glaze Studies',
      fileName: 'Terracotta Studio Identity.png',
      folderName: '',
      tags: ['ceramic', 'terracotta', 'minimal', '品牌', '陶土色'],
      rating: 4,
      notes: 'Earthy terracotta primary swatch paired with chalk off-white stationery.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="900" height="1100" viewBox="0 0 900 1100">
        <defs>
          <linearGradient id="bgc" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#EBD8C0"/>
            <stop offset="100%" stop-color="#BE997C"/>
          </linearGradient>
        </defs>
        <rect width="900" height="1100" fill="url(#bgc)"/>
        <text x="64" y="128" fill="#4C301F" font-family="Georgia, serif" font-size="68" font-weight="700">BISQUE / GLAZE</text>
        <text x="69" y="176" fill="#775444" font-family="Helvetica Neue, sans-serif" font-size="18" font-weight="600">KILN STUDY 03</text>
        <ellipse cx="180" cy="720" rx="108" ry="26" fill="#482E20" opacity="0.2"/>
        <rect x="115" y="340" width="130" height="380" rx="58" fill="#9B5239"/>
        <ellipse cx="180" cy="348" rx="64" ry="18" fill="#BD6C50"/>
        <ellipse cx="450" cy="720" rx="108" ry="26" fill="#482E20" opacity="0.2"/>
        <rect x="385" y="420" width="130" height="300" rx="56" fill="#B18B65"/>
        <ellipse cx="450" cy="428" rx="64" ry="18" fill="#CDAC83"/>
        <ellipse cx="720" cy="720" rx="108" ry="26" fill="#482E20" opacity="0.2"/>
        <rect x="655" y="370" width="130" height="350" rx="56" fill="#6F765B"/>
        <ellipse cx="720" cy="378" rx="64" ry="18" fill="#9A9B77"/>
        <rect x="67" y="874" width="766" height="2" fill="#89664F" opacity="0.6"/>
        <text x="68" y="924" fill="#553829" font-family="Helvetica Neue, sans-serif" font-size="19" font-weight="600">01  OXIDE             02  SAND             03  CELADON</text>
      </svg>`,
    },
    {
      title: 'Limestone Courtyard — Study in Shadow',
      fileName: 'Limestone Courtyard.png',
      folderName: 'Architecture',
      tags: ['architecture', 'limestone', '建筑', '午后'],
      rating: 5,
      notes: 'A low sun cuts across three stone thresholds.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="900" viewBox="0 0 1200 900">
        <rect width="1200" height="900" fill="#D1AB7C"/>
        <rect x="0" y="750" width="1200" height="35" fill="#AE8965"/>
        <rect x="72" y="140" width="320" height="610" fill="#E2C29B"/>
        <rect x="126" y="240" width="210" height="510" rx="105" fill="#765943"/>
        <rect x="438" y="140" width="320" height="610" fill="#D9B38B"/>
        <rect x="492" y="240" width="210" height="510" rx="105" fill="#765943"/>
        <rect x="804" y="140" width="320" height="610" fill="#C89B71"/>
        <rect x="858" y="240" width="210" height="510" rx="105" fill="#765943"/>
        <polygon points="0,785 1050,785 0,260" fill="#594333" opacity="0.26"/>
        <text x="70" y="844" fill="#443126" font-family="Helvetica Neue, sans-serif" font-size="22" font-weight="600">COURTYARD  /  03</text>
      </svg>`,
    },
    {
      title: 'Herbarium — Silver Eucalyptus',
      fileName: 'Silver Eucalyptus.png',
      folderName: '',
      tags: ['botanical', 'sage', '植物', '叶片'],
      rating: 4,
      notes: 'An archival plate studying stems and paired leaves.',
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="900" height="1160" viewBox="0 0 900 1160">
        <rect width="900" height="1160" fill="#E8E5D5"/>
        <rect x="44" y="44" width="812" height="1072" fill="none" stroke="#A39C81" stroke-width="2"/>
        <path d="M 310 945 Q 550 590 540 205" stroke="#66734E" stroke-width="5" fill="none"/>
        ${Array.from({ length: 10 }, (_, i) => {
          const t = i / 9;
          const x = 355 + 190 * t;
          const y = 840 - 540 * t;
          const dir = i % 2 === 0 ? 38 : -38;
          const fill = ['#80916E', '#A2AD8C', '#687A58'][i % 3];
          return `<ellipse cx="${x}" cy="${y}" rx="34" ry="${110 - t * 38}" fill="${fill}" opacity="0.9" transform="rotate(${dir} ${x} ${y})"/>`;
        }).join('')}
        <text x="86" y="1044" fill="#3F523A" font-family="Georgia, serif" font-size="42" font-weight="600">Eucalyptus cinerea</text>
        <text x="89" y="1084" fill="#58654D" font-family="Helvetica Neue, sans-serif" font-size="15">HERBARIUM  /  SILVER DOLLAR</text>
      </svg>`,
    },
  ];
}

/**
 * Generates a gentle, playable 2.4-second warm ambient chord WAV clip (16-bit PCM mono 22050 Hz)
 * so the Audio Studio Waveform Quick Look player works out of the box with real audio!
 */
function buildSampleAmbientWav(): Uint8Array {
  const sampleRate = 22050;
  const durationSec = 2.4;
  const numSamples = Math.floor(sampleRate * durationSec);
  const dataSize = numSamples * 2;
  const bytes = new Uint8Array(44 + dataSize);
  const view = new DataView(bytes.buffer);
  const writeAscii = (offset: number, str: string) => {
    for (let i = 0; i < str.length; i++) bytes[offset + i] = str.charCodeAt(i);
  };

  writeAscii(0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(36, 'data');
  view.setUint32(40, dataSize, true);

  const freqs = [220, 277.18, 329.63, 440]; // A major warm ambient chord
  for (let i = 0; i < numSamples; i++) {
    const t = i / sampleRate;
    const env = Math.sin((Math.PI * t) / durationSec) * (0.65 + 0.35 * Math.sin(t * 7.5));
    let sample = 0;
    for (let f = 0; f < freqs.length; f++) {
      sample += Math.sin(2 * Math.PI * freqs[f] * t) * (0.28 / (f * 0.35 + 1));
    }
    const int16 = Math.max(-32767, Math.min(32767, Math.round(sample * env * 26000)));
    view.setInt16(44 + i * 2, int16, true);
  }
  return bytes;
}

/**
 * Generates a valid, clean architectural prism OBJ 3D model so the Three.js WebGL orbit viewer
 * works immediately out of the box.
 */
function buildSamplePrismObj(): Uint8Array {
  const obj = `# Charkle Sample Architectural Prism
o ArchitecturalPrism
v -1.0 -0.8  1.0
v  1.0 -0.8  1.0
v  1.0 -0.8 -1.0
v -1.0 -0.8 -1.0
v -0.65  1.1  0.65
v  0.65  1.1  0.65
v  0.65  1.1 -0.65
v -0.65  1.1 -0.65
v  0.0   1.65 0.0
f 1 2 3 4
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
f 5 6 9
f 6 7 9
f 7 8 9
f 8 5 9
`;
  return utf8Encode(obj);
}

/**
 * Seeds a curated starter library on an empty database (idempotent — returns false if already non-empty).
 */
export async function seedSampleLibrary(
  db: LibraryDatabase,
  media: IMediaPipeline,
  force = false,
): Promise<boolean> {
  if (!force && !db.isEmpty()) {
    return false;
  }

  // 1. Create starter folders with macOS parity colors & symbols
  const folderSpecs: Array<{ name: string; colorHex: string; customSymbol: string }> = [
    { name: 'Architecture', colorHex: '#FF9F0A', customSymbol: 'sf:building.columns' },
    { name: 'Editorial', colorHex: '#FF453A', customSymbol: 'sf:book.closed' },
    { name: 'Typography', colorHex: '#BF5AF2', customSymbol: 'sf:textformat' },
    { name: 'UI Inspiration', colorHex: '#0A84FF', customSymbol: 'sf:macwindow' },
  ];

  const folderByName = new Map<string, FolderRecord>();
  for (const spec of folderSpecs) {
    let f = db.findFolderByPath(spec.name);
    if (!f) {
      f = db.createFolder(spec.name, null);
      f = db.updateFolderAppearance(f.id, {
        colorHex: spec.colorHex,
        customSymbol: spec.customSymbol,
      });
    }
    folderByName.set(spec.name, f);
  }

  // 2. Render & ingest all 10 editorial artworks
  const specs = buildStudioArtworks();
  const createdAssets: AssetRecord[] = [];
  for (const spec of specs) {
    const rendered = await media.images.renderArtworkCard({ kind: 'svg', svg: spec.svg });
    const imgBytes = rendered.fullImage;
    const isSvg = sniffImageMimeType(imgBytes) === 'image/svg+xml';
    const fileName = isSvg ? spec.fileName.replace(/\.png$/i, '.svg') : spec.fileName;
    const mimeType = isSvg ? 'image/svg+xml' : 'image/png';
    const folderID = spec.folderName ? (folderByName.get(spec.folderName)?.id ?? null) : null;
    const ingested = await media.ingestUploadedFile(imgBytes, fileName, mimeType, folderID);
    const enriched: AssetRecord = {
      ...ingested.asset,
      mediaKind: 'image',
      title: spec.title,
      tags: spec.tags,
      rating: spec.rating,
      notes: spec.notes,
    };
    const saved = db.saveAssetLocally(enriched);
    if (ingested.vector) {
      db.saveVector(saved.id, ingested.vector);
    }
    db.touchOriginal(saved.id);
    createdAssets.push(saved);
  }

  // 3. Curated GitHub Repo card (offline-ready, zero external network required)
  const uiFolderID = folderByName.get('UI Inspiration')?.id ?? null;
  const ghMeta: GitHubRepoMetadata = {
    owner: 'charkle-studio',
    repo: 'gallery-design-tokens',
    fullName: 'charkle-studio/gallery-design-tokens',
    description: 'Neutral studio surfaces, concentric radii, CIELAB palettes, and calibrated motion curves for visual curation tools.',
    stars: 2840,
    forks: 196,
    watchers: 84,
    language: 'TypeScript',
    licenseName: 'MIT',
    topics: ['design-tokens', 'cielab', 'moodboard', 'typography', 'motion'],
    defaultBranch: 'main',
    homepageURL: 'https://charkle.app',
    openGraphImageURL: 'https://opengraph.githubassets.com/1/charkle-studio/gallery-design-tokens',
    readmeMarkdown: `# Gallery Design Tokens\n\nA calm, artwork-first token system built around neutral paper/obsidian surfaces and perceptual CIELAB harmony.\n\n## Core Surfaces\n\n| Token | Light | Dark |\n|---|---|---|\n| \`galleryGround\` | \`#F6F6F5\` | \`#141517\` |\n| \`surfaceElevated\` | \`#FFFFFF\` | \`#1E2025\` |\n| \`inspectorBg\` | \`#F1F0EC\` | \`#131519\` |\n\n## Motion Curves\n\n- **Enter**: \`cubic-bezier(0, 0, 0.58, 1)\`\n- **Settle Strong**: \`cubic-bezier(0.22, 1, 0.36, 1)\`\n- **Micro Overshoot (<= 64px)**: \`cubic-bezier(0.34, 1.56, 0.64, 1)\`\n`,
    fetchedAt: new Date().toISOString(),
  };
  const ghCard = await media.images.renderArtworkCard({ kind: 'githubRepo', repo: ghMeta });
  const ghId = toSwiftUUID(randomUUID());
  await media.writeThumbnail(ghId, 'grid520', ghCard.grid520, ghCard.mimeType);
  if (ghCard.preview1400) {
    await media.writeThumbnail(ghId, 'preview1400', ghCard.preview1400, ghCard.mimeType);
  }
  const ghColors = await media.extractDominantColors(ghCard.fullImage, 5);
  const ghFp = await media.computeVisualFingerprint(ghCard.fullImage);
  const ghAsset = createDefaultAssetRecord({
    id: ghId,
    title: ghMeta.fullName,
    fileName: 'charkle-studio-gallery-design-tokens.webloc',
    folderID: uiFolderID,
    contentHash: sha256HexSync(ghMeta.fullName),
    mediaKind: 'webBookmark',
    mimeType: 'application/xml',
    fileSizeBytes: 256,
    pixelWidth: ghCard.width,
    pixelHeight: ghCard.height,
    sourceURL: 'https://github.com/charkle-studio/gallery-design-tokens',
    sourceDomain: 'github.com',
    notes: ghMeta.description ?? '',
    tags: ['GitHub', 'TypeScript', 'design-tokens'],
    rating: 5,
    dominantColors: ghColors,
    isLocalOriginalCached: true,
    richMetadata: {
      githubRepo: ghMeta,
      socialPost: null,
      textExcerpt: ghMeta.readmeMarkdown?.slice(0, 1200) ?? null,
      isMarkdown: true,
      model3DFormat: null,
    },
  });
  await media.installOriginal(utf8Encode(ghMeta.readmeMarkdown ?? ''), ghAsset);
  db.saveAssetLocally(ghAsset);
  db.saveVector(ghId, { featurePrint: encodeFeaturePrintFloat32(ghFp), precision: 16 });
  db.touchOriginal(ghId);

  // 4. Curated Cohesive X Social Post card (strictly mediaKind = 'webBookmark')
  const editorialFolderID = folderByName.get('Editorial')?.id ?? null;
  const socialMeta: SocialPostMetadata = {
    platform: 'x',
    authorName: 'Atelier Kuro',
    authorHandle: 'atelier_kuro',
    publishedAtText: '2026-11-20',
    bodyText:
      '好的情绪板界面应该像美术馆的素白墙面：工具栏克制退后，让每一张图片、材质与色温自己说话。Light, Paper & Clay.',
    mediaURLs: [],
    mediaThumbnailURLs: [],
    attachments: [],
    hasVideo: false,
    replyCount: 38,
    repostCount: 214,
    likeCount: 1640,
    viewCount: 48200,
    originalURL: 'https://x.com/atelier_kuro/status/1860000000000000001',
    mediaFetchFailed: false,
  };
  const socialCard = await media.images.renderArtworkCard({
    kind: 'socialPost',
    post: socialMeta,
    coverImageBytes: null,
  });
  const socialId = toSwiftUUID(randomUUID());
  await media.writeThumbnail(socialId, 'grid520', socialCard.grid520, socialCard.mimeType);
  if (socialCard.preview1400) {
    await media.writeThumbnail(socialId, 'preview1400', socialCard.preview1400, socialCard.mimeType);
  }
  const socialColors = await media.extractDominantColors(socialCard.fullImage, 5);
  const socialFp = await media.computeVisualFingerprint(socialCard.fullImage);
  const socialArchive = `# ${socialMeta.authorName} (@${socialMeta.authorHandle}) · X\n\n${socialMeta.bodyText}\n\n${socialMeta.originalURL}\n`;
  const socialArchiveBytes = utf8Encode(socialArchive);
  const socialAsset = createDefaultAssetRecord({
    id: socialId,
    title: 'Atelier Kuro: 好的情绪板界面应该像美术馆的素白墙面…',
    fileName: 'atelier_kuro-post.md',
    folderID: editorialFolderID,
    contentHash: sha256HexSync(socialArchiveBytes),
    mediaKind: 'webBookmark',
    mimeType: 'text/markdown',
    fileSizeBytes: socialArchiveBytes.byteLength,
    pixelWidth: socialCard.width,
    pixelHeight: socialCard.height,
    sourceURL: socialMeta.originalURL,
    sourceDomain: 'x.com',
    notes: 'Cohesive X post reference',
    tags: ['X', 'editorial', '设计思考'],
    ocrText: socialMeta.bodyText,
    rating: 4,
    dominantColors: socialColors,
    isLocalOriginalCached: true,
    richMetadata: {
      githubRepo: null,
      socialPost: socialMeta,
      textExcerpt: socialMeta.bodyText,
      isMarkdown: false,
      model3DFormat: null,
    },
  });
  await media.installOriginal(socialArchiveBytes, socialAsset);
  db.saveAssetLocally(socialAsset);
  db.saveVector(socialId, { featurePrint: encodeFeaturePrintFloat32(socialFp), precision: 16 });
  db.touchOriginal(socialId);

  // 5. Markdown Note + Color Swatch + Sample Ambient Audio WAV + Sample OBJ 3D Prism
  const mdIngested = await media.ingest(
    {
      type: 'textSnippet',
      title: '策展笔记 · 光影与材质系统',
      text: `# 光影与材质系统\n\n- **暖陶土与石灰岩**：在自然斜射光下保留 12–18% 的阴影透气感。\n- **字体节奏**：大号衬线标题搭配克制的等宽标注，避免过度装饰。\n- **色板收敛**：单块情绪板核心色保持 5–7 枚 CIELAB 均衡色块。\n`,
    },
    editorialFolderID,
  );
  mdIngested.asset.tags = ['markdown', '笔记', '策展'];
  mdIngested.asset.rating = 4;
  db.saveAssetLocally(mdIngested.asset);
  if (mdIngested.vector) db.saveVector(mdIngested.asset.id, mdIngested.vector);

  const swatchIngested = await media.ingest(
    { type: 'colorSwatch', hex: '#C86D51', title: 'Terracotta Ochre' },
    editorialFolderID,
  );
  swatchIngested.asset.tags = ['色卡', 'terracotta', '暖色调'];
  swatchIngested.asset.rating = 4;
  db.saveAssetLocally(swatchIngested.asset);
  if (swatchIngested.vector) db.saveVector(swatchIngested.asset.id, swatchIngested.vector);

  const wavIngested = await media.ingestUploadedFile(
    buildSampleAmbientWav(),
    'Studio Warm Ambience.wav',
    'audio/wav',
    folderByName.get('Architecture')?.id ?? null,
  );
  wavIngested.asset.title = 'Studio Warm Ambience';
  wavIngested.asset.tags = ['audio', 'ambient', '声景'];
  wavIngested.asset.notes = 'Synthesized warm A-major studio reference loop with 48-bar waveform.';
  wavIngested.asset.rating = 4;
  db.saveAssetLocally(wavIngested.asset);

  const objIngested = await media.ingestUploadedFile(
    buildSamplePrismObj(),
    'Architectural Prism.obj',
    'model/obj',
    folderByName.get('Architecture')?.id ?? null,
  );
  objIngested.asset.title = 'Architectural Prism 3D';
  objIngested.asset.tags = ['3d', 'architecture', '模型'];
  objIngested.asset.notes = 'Interactive WebGL geometric study prism.';
  objIngested.asset.rating = 5;
  db.saveAssetLocally(objIngested.asset);

  // 6. Starter Smart Folder
  const now = new Date().toISOString();
  db.saveSmartFolder({
    id: toSwiftUUID(randomUUID()),
    name: '高评分精选灵感',
    colorHex: '#D4A373',
    rule: createDefaultSmartFolderRule({
      matchMode: 'all',
      minRating: 4,
      mediaKinds: ['image', 'webBookmark'],
    }),
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
  });

  // 7. Curated Starter Moodboard ("光、纸与泥 · Light, Paper & Clay" referencing indices [1, 2, 4, 7, 8, 9])
  const pickIndices = [1, 2, 4, 7, 8, 9];
  const boardAssets = pickIndices
    .map((idx) => createdAssets[idx])
    .filter((a): a is AssetRecord => Boolean(a));

  const boardNodes: BoardNode[] = boardAssets.map((a, idx) => ({
    id: toSwiftUUID(randomUUID()),
    kind: {
      type: 'assetRef',
      assetID: a.id,
      crop: null,
      weight: idx === 0 ? 2 : 1,
      autoplayLoop: true,
    },
    frame: { x: 40 + (idx % 3) * 320, y: 120 + Math.floor(idx / 3) * 340, width: 290, height: 300 },
    zIndex: idx + 1,
    rotationDegrees: 0,
    flipHorizontal: false,
    flipVertical: false,
    isLocked: false,
    editorialOrder: idx,
    updatedAt: now,
  }));

  boardNodes.push({
    id: toSwiftUUID(randomUUID()),
    kind: {
      type: 'note',
      title: '策展说明',
      text: '以温润陶土、石灰岩午后斜影与瑞士纸面排版串联起「光、纸与泥」的触感基调。',
      style: 'warm',
      fontSize: 14,
    },
    frame: { x: 40, y: 820, width: 320, height: 156 },
    zIndex: 20,
    rotationDegrees: 0,
    flipHorizontal: false,
    flipVertical: false,
    isLocked: false,
    editorialOrder: boardNodes.length,
    updatedAt: now,
  });

  const paletteHexes = ['#D9B38B', '#C46A34', '#E8E5D5', '#80916E', '#765943', '#191816'];
  const extractedPalette = paletteHexes.map((hex, i) => labFromHex(hex, (6 - i) / 21));

  const starterBoardDraft = createDefaultMoodboardDocument({
    id: toSwiftUUID(randomUUID()),
    title: '光、纸与泥 · Light, Paper & Clay',
    subtitle: '材质、建筑阴影与暖色纸面排版参考集',
    mode: {
      type: 'autoEditorial',
      config: createDefaultAutoLayoutConfig({
        columns: 3,
        spacing: 18,
        style: 'magazine',
        showPaletteStrip: true,
      }),
    },
    nodes: boardNodes,
    extractedPalette,
    candidateAssetIDs: createdAssets
      .filter((a) => !boardAssets.some((b) => b.id === a.id))
      .map((a) => a.id),
    pinnedOffline: false,
    createdAt: now,
    updatedAt: now,
  });

  const boardAssetsByID: Record<string, AssetRecord> = {};
  for (const a of boardAssets) {
    boardAssetsByID[a.id] = a;
  }
  const starterBoard = freezeIntoFreeform(starterBoardDraft, 1080, boardAssetsByID);

  db.saveBoardLocally(starterBoard);
  return true;
}

export const SampleLibrarySeeder = {
  seed: seedSampleLibrary,
} as const;
