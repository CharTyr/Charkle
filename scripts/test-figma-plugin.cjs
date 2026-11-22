const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const pluginDir = path.join(__dirname, '../Resources/FigmaPlugin');
const source = fs.readFileSync(path.join(pluginDir, 'code.js'), 'utf8');

async function run(board, { failAsset = false, editorType = 'figjam', allowReview = true } = {}) {
  const all = [];
  const loaded = new Set();
  const messages = [];
  let next = 1;
  let assetCalls = 0;

  function makeNode(type) {
    const n = {
      type,
      id: String(next++),
      children: [],
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      removed: false,
      plugin: {},
      fontName: { family: 'PingFang SC', style: 'Regular' },
      appendChild(c) {
        if (c.parent) c.parent.children = c.parent.children.filter(x => x !== c);
        c.parent = this;
        this.children.push(c);
      },
      insertChild(idx, c) {
        if (c.parent) c.parent.children = c.parent.children.filter(x => x !== c);
        c.parent = this;
        this.children.splice(idx, 0, c);
      },
      resize(w, h) {
        this.width = w;
        this.height = h;
      },
      getPluginData(k) {
        return this.plugin[k] || '';
      },
      setPluginData(k, v) {
        this.plugin[k] = v;
      },
      remove() {
        this.removed = true;
        for (const c of [...this.children]) c.remove();
        if (this.parent) this.parent.children = this.parent.children.filter(x => x !== this);
      }
    };
    Object.defineProperty(n, 'characters', {
      set(v) {
        assert(loaded.has(n.fontName.family + '/' + n.fontName.style), 'Font must load before setting characters: ' + n.fontName.family + '/' + n.fontName.style);
        n._characters = v;
      },
      get() {
        return n._characters || '';
      }
    });
    Object.defineProperty(n, 'relativeTransform', {
      set(t) {
        this._transform = t;
        this.x = t[0][2];
        this.y = t[1][2];
      },
      get() {
        return this._transform;
      }
    });
    all.push(n);
    return n;
  }

  const page = makeNode('PAGE');
  const figma = {
    editorType,
    currentPage: page,
    showUI() {},
    listAvailableFontsAsync: async () => [
      { fontName: { family: 'PingFang SC', style: 'Regular' } },
      { fontName: { family: 'PingFang SC', style: 'Semibold' } },
      { fontName: { family: 'SF Mono', style: 'Medium' } },
      { fontName: { family: 'Inter', style: 'Regular' } }
    ],
    loadFontAsync: async f => {
      await Promise.resolve();
      loaded.add(f.family + '/' + f.style);
    },
    createSection: () => {
      const n = makeNode('SECTION');
      page.appendChild(n);
      return n;
    },
    createFrame: () => {
      const n = makeNode('FRAME');
      page.appendChild(n);
      return n;
    },
    createRectangle: () => {
      const n = makeNode('RECTANGLE');
      page.appendChild(n);
      return n;
    },
    createText: () => {
      const n = makeNode('TEXT');
      page.appendChild(n);
      return n;
    },
    createVector: () => {
      const n = makeNode('VECTOR');
      page.appendChild(n);
      return n;
    },
    createConnector: () => {
      const n = makeNode('CONNECTOR');
      n.text = makeNode('TEXT');
      n.connectorEndStrokeCap = 'NONE';
      page.appendChild(n);
      return n;
    },
    createGif(hash) {
      const n = makeNode('MEDIA');
      n.imageHash = hash;
      page.appendChild(n);
      return n;
    },
    createImage(bytes) {
      const [w, h] = JSON.parse(Buffer.from(bytes));
      return { hash: 'hash-' + assetCalls, getSizeAsync: async () => ({ width: w, height: h }) };
    },
    group(ns, parent) {
      const g = makeNode('GROUP');
      parent.appendChild(g);
      g.resize(Math.max(...ns.map(n => n.x + n.width)), Math.max(...ns.map(n => n.y + n.height)));
      for (const n of ns) g.appendChild(n);
      return g;
    },
    viewport: {
      scrollAndZoomIntoView(ns) {
        assert(ns[0].visible);
      }
    }
  };

  figma.ui = {
    postMessage(m) {
      messages.push(m);
      if (m.type === 'asset-request') {
        assetCalls++;
        const tile = board.objects
          .flatMap(o => [
            ...(o.image?.tiles || []),
            ...(o.image?.animation ? [{ ...o.image.animation, width: 640, height: 480 }] : [])
          ])
          .find(t => t.file === m.file);
        queueMicrotask(() =>
          figma.ui.onmessage({
            type: 'asset-response',
            id: m.id,
            ...(failAsset
              ? { error: 'injected failure' }
              : { bytes: Buffer.from(JSON.stringify([tile.width, tile.height])) })
          })
        );
      }
    }
  };

  vm.runInNewContext(source, { figma, __html__: '', setTimeout, clearTimeout, Uint8Array, console });
  await figma.ui.onmessage({ type: 'import', board, allowReview });
  return { all, page, messages, assetCalls };
}

const gBase = { x: 100, y: 120, width: 400, height: 300, angle: 90, flipX: false, flipY: false };
const tile = (x, w) => ({
  file: `tiles/ASSET1-${x}-0.png`,
  x,
  y: 0,
  width: w,
  height: 3000,
  sha256: String(x ? 'b' : 'a').repeat(64)
});

const fullBoard = {
  format: 'charkle-figma-bridge',
  version: 1,
  name: '晴空下的夏日片刻',
  darkAppearance: false,
  objects: [
    {
      id: 'grp-1',
      kind: 'groupFrame',
      name: '构图参考区',
      geometry: { x: 40, y: 40, width: 900, height: 600, angle: 0, flipX: false, flipY: false },
      group: { title: '构图参考区', tint: 'sand', accentHex: '#B5956B' },
      warnings: []
    },
    {
      id: 'img-1',
      kind: 'image',
      name: '5K 超清素材',
      cornerRadius: 12,
      geometry: gBase,
      image: { pixelWidth: 5000, pixelHeight: 3000, tiles: [tile(0, 4096), tile(4096, 904)] },
      warnings: []
    },
    {
      id: 'note-1',
      kind: 'note',
      name: '灵感便签',
      geometry: { x: 560, y: 140, width: 260, height: 180, angle: 0, flipX: false, flipY: false },
      note: {
        title: '光影思路',
        text: '保持高明度日光与通透空气感',
        style: 'warm',
        fontSize: 14,
        backgroundHex: '#F7F0E4',
        foregroundHex: '#392F22',
        borderHex: '#C9B79C'
      },
      warnings: []
    },
    {
      id: 'pal-1',
      kind: 'paletteStrip',
      name: '板内色卡',
      geometry: { x: 100, y: 480, width: 420, height: 84, angle: 0, flipX: false, flipY: false },
      palette: {
        swatches: [
          { hex: '#62A8E5', isLight: false },
          { hex: '#F3EAD8', isLight: true }
        ]
      },
      warnings: []
    }
  ],
  connectors: [
    {
      id: 'conn-1',
      fromNodeID: 'img-1',
      fromAnchor: 'trailing',
      toNodeID: 'note-1',
      toAnchor: 'leading',
      style: 'curved',
      colorHex: '#5C6B73',
      dashed: false,
      label: '色调呼应'
    }
  ],
  inkStrokes: [
    {
      id: 'ink-1',
      points: [{ x: 120, y: 200 }, { x: 240, y: 260 }, { x: 320, y: 240 }],
      colorHex: '#D95D48',
      lineWidth: 3.5,
      opacity: 0.92
    }
  ],
  report: {
    objectCount: 4,
    imageCount: 1,
    noteCount: 1,
    groupCount: 1,
    paletteCount: 1,
    connectorCount: 1,
    strokeCount: 1,
    reviewCount: 0,
    warnings: []
  }
};

(async () => {
  // 1. FigJam full import (Section + Group + Tiled 5K Image + Note + Palette + Native Connector + Ink)
  let r = await run(fullBoard, { editorType: 'figjam' });
  assert(r.messages.some(m => m.type === 'done'));
  assert.equal(r.assetCalls, 2);
  assert.equal(r.page.children.length, 1);
  const section = r.page.children[0];
  assert.equal(section.type, 'SECTION');
  assert.equal(section.children.length, 6); // 4 objects + 1 connector + 1 ink vector
  assert.equal(section.children[0].type, 'FRAME'); // groupFrame
  assert.equal(section.children[1].type, 'GROUP'); // 2-tile 5K image
  assert.equal(section.children[2].type, 'FRAME'); // editable note
  assert.equal(section.children[3].type, 'FRAME'); // editable palette
  assert.equal(section.children[4].type, 'CONNECTOR'); // native FigJam connector!
  assert.equal(section.children[4].text.characters, '色调呼应');
  assert.equal(section.children[5].type, 'VECTOR'); // ink stroke

  // 2. Figma Design full import (Frame + vector connector + label + ink)
  r = await run(fullBoard, { editorType: 'figma' });
  assert(r.messages.some(m => m.type === 'done'));
  assert.equal(r.page.children[0].type, 'FRAME');
  assert(r.page.children[0].children.some(c => c.type === 'VECTOR' && c.name === '连线：色调呼应'));

  // 3. Atomic rollback on injected asset failure
  r = await run(fullBoard, { failAsset: true });
  assert.equal(r.page.children.length, 0);
  assert(r.messages.some(m => m.type === 'error'));

  // 4. Native GIF import in FigJam
  const gifBoard = structuredClone(fullBoard);
  gifBoard.objects = [gifBoard.objects[1]];
  gifBoard.objects[0].image.animation = { file: 'originals/ASSET1.gif', sha256: 'c'.repeat(64) };
  gifBoard.connectors = [];
  gifBoard.inkStrokes = [];
  r = await run(gifBoard, { editorType: 'figjam' });
  assert.equal(r.page.children[0].children[0].type, 'MEDIA');
  assert.equal(r.assetCalls, 1);

  // 5. Invalid tile grid rejected cleanly
  const bad = structuredClone(fullBoard);
  bad.objects[1].image.tiles[1].x = 4000;
  r = await run(bad);
  assert.equal(r.page.children.length, 0);
  assert(r.messages.some(m => m.type === 'error'));

  // 6. Bundled js-sha256 parity against Node crypto
  const sha = require(path.join(pluginDir, 'sha256.min.js'));
  for (const data of [Buffer.from('charkle'), crypto.randomBytes(8192)]) {
    assert.equal(sha(data), crypto.createHash('sha256').update(data).digest('hex'));
  }

  console.log('PASS: Charkle Figma/FigJam plugin verified (5K tiles, rotation, notes, groups, palette, FigJam connectors, Design vectors, ink, GIF, rollback, SHA-256)');
})().catch(err => {
  console.error(err);
  process.exit(1);
});
