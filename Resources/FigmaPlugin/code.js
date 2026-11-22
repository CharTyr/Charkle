/* Charkle -> Figma Design / FigJam offline streaming importer. */
figma.showUI(__html__, { width: 460, height: 600, themeColors: true });

let running = false;
let canceled = false;
const pending = new Map();
let requestNumber = 0;

function requestAsset(file) {
  return new Promise((resolve, reject) => {
    const id = ++requestNumber;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error('图片读取超时：' + file));
    }, 60000);
    pending.set(id, { resolve, reject, timer });
    figma.ui.postMessage({ type: 'asset-request', id, file });
  });
}

function safeNumber(n) {
  return typeof n === 'number' && Number.isFinite(n);
}

function parseHexRGB(hex, fallback) {
  const def = fallback || { r: 0.25, g: 0.27, b: 0.30 };
  if (typeof hex !== 'string') return def;
  const cleaned = hex.trim().replace(/^#/, '');
  if (!/^[0-9a-fA-F]{6}$/.test(cleaned)) return def;
  return {
    r: parseInt(cleaned.slice(0, 2), 16) / 255,
    g: parseInt(cleaned.slice(2, 4), 16) / 255,
    b: parseInt(cleaned.slice(4, 6), 16) / 255
  };
}

function validate(board) {
  if (!board || board.format !== 'charkle-figma-bridge' || board.version !== 1 || !Array.isArray(board.objects)) {
    throw new Error('导出包格式不受支持，请使用 Charkle 导出的 .charkleboard 文件。');
  }
  if (board.objects.length < 1 || board.objects.length > 10000) {
    throw new Error('情绪板对象数量无效。');
  }
  const ids = new Set();
  const allowedKinds = ['image', 'note', 'groupFrame', 'paletteStrip', 'unsupported'];
  for (const object of board.objects) {
    if (typeof object.id !== 'string' || ids.has(object.id)) {
      throw new Error('对象标识重复或缺失。');
    }
    ids.add(object.id);
    if (!allowedKinds.includes(object.kind)) {
      throw new Error('对象类型不受支持：' + object.kind);
    }
    if (object.kind === 'unsupported') continue;
    const g = object.geometry;
    if (
      !g ||
      !['x', 'y', 'width', 'height', 'angle'].every(k => safeNumber(g[k])) ||
      g.width <= 0 ||
      g.height <= 0 ||
      g.width > 1e7 ||
      g.height > 1e7
    ) {
      throw new Error('对象坐标或尺寸无效：' + (object.name || object.id));
    }
    if (object.kind === 'image') {
      const im = object.image;
      if (
        !im ||
        !Number.isInteger(im.pixelWidth) ||
        !Number.isInteger(im.pixelHeight) ||
        im.pixelWidth <= 0 ||
        im.pixelHeight <= 0 ||
        !Array.isArray(im.tiles) ||
        !im.tiles.length
      ) {
        throw new Error('图片数据无效：' + (object.name || object.id));
      }
      if (im.tiles.length !== Math.ceil(im.pixelWidth / 4096) * Math.ceil(im.pixelHeight / 4096)) {
        throw new Error('图片分块数量不一致：' + (object.name || object.id));
      }
      if (
        im.animation &&
        (!/^originals\/[A-Za-z0-9._-]+\.gif$/i.test(im.animation.file) || !/^[a-f0-9]{64}$/.test(im.animation.sha256))
      ) {
        throw new Error('GIF 路径或校验值无效。');
      }
      const seen = new Set();
      for (const tile of im.tiles) {
        if (typeof tile.file !== 'string' || !/^tiles\/[A-Za-z0-9._-]+\.png$/i.test(tile.file) || !/^[a-f0-9]{64}$/.test(tile.sha256)) {
          throw new Error('图片图块路径或校验值无效。');
        }
        if (
          !['x', 'y', 'width', 'height'].every(k => Number.isInteger(tile[k])) ||
          tile.x < 0 ||
          tile.y < 0 ||
          tile.width <= 0 ||
          tile.height <= 0 ||
          tile.width > 4096 ||
          tile.height > 4096 ||
          tile.x + tile.width > im.pixelWidth ||
          tile.y + tile.height > im.pixelHeight
        ) {
          throw new Error('图片分块范围无效。');
        }
        if (
          tile.x % 4096 ||
          tile.y % 4096 ||
          tile.width !== Math.min(4096, im.pixelWidth - tile.x) ||
          tile.height !== Math.min(4096, im.pixelHeight - tile.y)
        ) {
          throw new Error('图片分块网格无效。');
        }
        const key = tile.x + ':' + tile.y;
        if (seen.has(key)) throw new Error('图片分块重复。');
        seen.add(key);
      }
    }
  }
}

function transform(g, origin) {
  // Charkle SwiftUI `.rotationEffect(.degrees(d))` is clockwise in y-down screen coordinates;
  // flip is applied inside rotation around the node's center.
  const radians = (g.angle || 0) * Math.PI / 180;
  const cos = Math.cos(radians);
  const sin = Math.sin(radians);
  const sx = g.flipX ? -1 : 1;
  const sy = g.flipY ? -1 : 1;
  const a = cos * sx;
  const b = sin * sx;
  const c = -sin * sy;
  const d = cos * sy;
  const cx = g.x - origin.x + g.width / 2;
  const cy = g.y - origin.y + g.height / 2;
  return [
    [a, c, cx - (a * g.width / 2 + c * g.height / 2)],
    [b, d, cy - (b * g.width / 2 + d * g.height / 2)]
  ];
}

function bounds(board) {
  const points = [];
  for (const object of board.objects) {
    if (!object.geometry) continue;
    const g = object.geometry;
    const t = transform(g, { x: 0, y: 0 });
    for (const [x, y] of [
      [0, 0],
      [g.width, 0],
      [0, g.height],
      [g.width, g.height]
    ]) {
      points.push([t[0][0] * x + t[0][1] * y + t[0][2], t[1][0] * x + t[1][1] * y + t[1][2]]);
    }
  }
  for (const stroke of board.inkStrokes || []) {
    for (const pt of stroke.points || []) {
      if (safeNumber(pt.x) && safeNumber(pt.y)) points.push([pt.x, pt.y]);
    }
  }
  if (!points.length) return { x: 0, y: 0, width: 800, height: 600 };
  const pad = 28;
  const minX = Math.min(...points.map(p => p[0])) - pad;
  const minY = Math.min(...points.map(p => p[1])) - pad;
  const maxX = Math.max(...points.map(p => p[0])) + pad;
  const maxY = Math.max(...points.map(p => p[1])) + pad;
  return {
    x: minX,
    y: minY,
    width: Math.max(120, maxX - minX),
    height: Math.max(120, maxY - minY)
  };
}

function pickFont(fonts, preferredFamilies, preferredStyles) {
  for (const family of preferredFamilies) {
    for (const style of preferredStyles) {
      const hit = fonts.find(f => f.fontName.family === family && f.fontName.style === style);
      if (hit) return hit.fontName;
    }
    const anyStyle = fonts.find(f => f.fontName.family === family);
    if (anyStyle) return anyStyle.fontName;
  }
  return (
    fonts.find(f => f.fontName.family === 'Inter' && f.fontName.style === 'Regular')?.fontName ||
    fonts[0]?.fontName
  );
}

function anchorPoint(g, anchor) {
  const cx = g.x + g.width / 2;
  const cy = g.y + g.height / 2;
  switch (anchor) {
    case 'top':
      return { x: cx, y: g.y };
    case 'bottom':
      return { x: cx, y: g.y + g.height };
    case 'leading':
    case 'left':
      return { x: g.x, y: cy };
    case 'trailing':
    case 'right':
      return { x: g.x + g.width, y: cy };
    default:
      return { x: cx, y: cy };
  }
}

function resolveConnectorEndpoints(fromG, fromAnchor, toG, toAnchor) {
  let fa = fromAnchor || 'auto';
  let ta = toAnchor || 'auto';
  if (fa === 'auto' || ta === 'auto') {
    const dx = toG.x + toG.width / 2 - (fromG.x + fromG.width / 2);
    const dy = toG.y + toG.height / 2 - (fromG.y + fromG.height / 2);
    if (Math.abs(dx) >= Math.abs(dy)) {
      if (fa === 'auto') fa = dx >= 0 ? 'trailing' : 'leading';
      if (ta === 'auto') ta = dx >= 0 ? 'leading' : 'trailing';
    } else {
      if (fa === 'auto') fa = dy >= 0 ? 'bottom' : 'top';
      if (ta === 'auto') ta = dy >= 0 ? 'top' : 'bottom';
    }
  }
  return { start: anchorPoint(fromG, fa), end: anchorPoint(toG, ta), fromAnchor: fa, toAnchor: ta };
}

function magnetName(anchor) {
  switch (anchor) {
    case 'top':
      return 'TOP';
    case 'bottom':
      return 'BOTTOM';
    case 'leading':
    case 'left':
      return 'LEFT';
    case 'trailing':
    case 'right':
      return 'RIGHT';
    default:
      return 'AUTO';
  }
}

function finalReport(board, importedCount, runtimeWarnings) {
  const resolved =
    figma.editorType === 'figjam'
      ? board.objects.filter(o => o.image && o.image.animation).map(o => o.id)
      : [];
  const animationIssues = new Set(['动画 GIF 在 Figma Design 中以静态首帧导入，原始 GIF 已归档']);
  const warnings = (board.report?.warnings || [])
    .map(w => ({
      ...w,
      issues: resolved.includes(w.id) ? w.issues.filter(issue => !animationIssues.has(issue)) : w.issues
    }))
    .filter(w => w.issues.length);
  return {
    ...(board.report || {}),
    importedCount,
    runtimeWarnings,
    warnings,
    reviewCount: warnings.length,
    animationCount: resolved.length,
    resolvedAnimationIds: resolved
  };
}

async function importBoard(board, allowReview) {
  validate(board);
  const review = (board.report?.warnings || []).length;
  if (review && !allowReview) {
    throw new Error('此导出包有 ' + review + ' 条核对提示，请先勾选确认后再导入。');
  }

  const runtimeWarnings = [];
  const needsFonts =
    board.objects.some(o => o.kind !== 'image') ||
    (board.connectors || []).some(c => c.label && c.label.length > 0);
  let regularFont = null;
  let boldFont = null;
  let monoFont = null;
  if (needsFonts) {
    const fonts = await figma.listAvailableFontsAsync();
    regularFont = pickFont(fonts, ['PingFang SC', 'SF Pro Text', 'Inter', 'Noto Sans SC'], ['Regular']);
    boldFont = pickFont(fonts, ['PingFang SC', 'SF Pro Display', 'Inter', 'Noto Sans SC'], ['Semibold', 'Semi Bold', 'Medium', 'Bold', 'Regular']);
    monoFont = pickFont(fonts, ['SF Mono', 'JetBrains Mono', 'Menlo', 'Inter'], ['Medium', 'Regular']);
    if (!regularFont) throw new Error('当前 Figma 没有可用字体。');
    const uniqueFonts = new Map();
    for (const f of [regularFont, boldFont, monoFont].filter(Boolean)) {
      uniqueFonts.set(f.family + '/' + f.style, f);
    }
    for (const f of uniqueFonts.values()) {
      await figma.loadFontAsync(f);
    }
  }

  const b = bounds(board);
  const existingRight = Math.max(0, ...figma.currentPage.children.map(n => n.x + n.width));
  const root = figma.editorType === 'figjam' ? figma.createSection() : figma.createFrame();
  root.name = board.name || 'Charkle 情绪板';
  const groundHex = board.darkAppearance ? '#141517' : '#F6F6F5';
  root.fills = [{ type: 'SOLID', color: parseHexRGB(groundHex) }];
  if ('clipsContent' in root) root.clipsContent = false;
  root.visible = false;
  root.resize(b.width, b.height);
  root.x = existingRight + 160;
  root.y = 0;
  root.setPluginData('charkleOrigin', JSON.stringify({ x: b.x, y: b.y, boardId: board.boardId || '' }));

  const imageCache = new Map();
  const nodeMap = new Map();
  const geometryMap = new Map();
  let imported = 0;
  const totalSteps =
    board.objects.length + (board.connectors ? board.connectors.length : 0) + (board.inkStrokes ? board.inkStrokes.length : 0);

  try {
    for (const object of board.objects) {
      if (canceled) throw new Error('导入已取消。');
      figma.ui.postMessage({
        type: 'progress',
        current: imported + 1,
        total: totalSteps,
        name: object.name || object.kind
      });

      let node;
      const g = object.geometry;

      if (object.kind === 'image' && object.image.animation && figma.editorType === 'figjam') {
        const bytes = await requestAsset(object.image.animation.file);
        node = figma.createGif(figma.createImage(new Uint8Array(bytes)).hash);
        root.appendChild(node);
        node.resize(g.width, g.height);
      } else if (object.kind === 'image') {
        const image = object.image;
        const rects = [];
        for (const tile of image.tiles) {
          if (canceled) throw new Error('导入已取消。');
          let hash = imageCache.get(tile.sha256);
          if (!hash) {
            const bytes = await requestAsset(tile.file);
            const im = figma.createImage(new Uint8Array(bytes));
            const size = await im.getSizeAsync();
            if (size.width !== tile.width || size.height !== tile.height) {
              throw new Error('图片分块像素尺寸不一致：' + tile.file);
            }
            hash = im.hash;
            imageCache.set(tile.sha256, hash);
          }
          const rect = figma.createRectangle();
          root.appendChild(rect);
          rects.push(rect);
          rect.name = image.tiles.length === 1 ? object.name || '素材' : '原始像素 ' + tile.x + ',' + tile.y;
          rect.resize((g.width * tile.width) / image.pixelWidth, (g.height * tile.height) / image.pixelHeight);
          rect.x = (g.width * tile.x) / image.pixelWidth;
          rect.y = (g.height * tile.y) / image.pixelHeight;
          rect.fills = [{ type: 'IMAGE', scaleMode: 'FILL', imageHash: hash }];
          if (image.tiles.length === 1 && safeNumber(object.cornerRadius) && object.cornerRadius > 0) {
            rect.cornerRadius = object.cornerRadius;
          }
        }
        node = rects.length === 1 ? rects[0] : figma.group(rects, root);
      } else if (object.kind === 'note') {
        const note = object.note || {};
        const card = figma.createFrame();
        root.appendChild(card);
        card.resize(g.width, g.height);
        card.cornerRadius = 12;
        card.fills = [{ type: 'SOLID', color: parseHexRGB(note.backgroundHex, { r: 0.97, g: 0.94, b: 0.89 }) }];
        card.strokes = [{ type: 'SOLID', color: parseHexRGB(note.borderHex, { r: 0.79, g: 0.72, b: 0.61 }), opacity: 0.45 }];
        card.strokeWeight = 1;
        card.clipsContent = true;

        const fgColor = parseHexRGB(note.foregroundHex, { r: 0.22, g: 0.18, b: 0.13 });
        const pad = 12;
        const innerW = Math.max(40, g.width - pad * 2);
        let cursorY = pad;

        if (note.title && String(note.title).trim().length > 0) {
          const titleNode = figma.createText();
          titleNode.fontName = boldFont || regularFont;
          titleNode.characters = String(note.title);
          titleNode.fontSize = Math.max(13, safeNumber(note.fontSize) ? note.fontSize : 14);
          titleNode.fills = [{ type: 'SOLID', color: fgColor }];
          titleNode.textAutoResize = 'HEIGHT';
          titleNode.resize(innerW, 20);
          titleNode.x = pad;
          titleNode.y = cursorY;
          card.appendChild(titleNode);
          cursorY += Math.max(22, titleNode.height) + 8;

          const divider = figma.createRectangle();
          divider.resize(innerW, 1);
          divider.x = pad;
          divider.y = cursorY - 4;
          divider.fills = [{ type: 'SOLID', color: fgColor, opacity: 0.12 }];
          card.appendChild(divider);
          cursorY += 4;
        }

        const bodyNode = figma.createText();
        bodyNode.fontName = regularFont;
        bodyNode.characters = String(note.text || '');
        bodyNode.fontSize = Math.max(11, (safeNumber(note.fontSize) ? note.fontSize : 14) - 1);
        bodyNode.fills = [{ type: 'SOLID', color: fgColor, opacity: 0.9 }];
        bodyNode.textAutoResize = 'NONE';
        bodyNode.resize(innerW, Math.max(20, g.height - cursorY - pad));
        bodyNode.x = pad;
        bodyNode.y = cursorY;
        card.appendChild(bodyNode);
        node = card;
      } else if (object.kind === 'groupFrame') {
        const grp = object.group || {};
        const accent = parseHexRGB(grp.accentHex, { r: 0.71, g: 0.58, b: 0.42 });
        const box = figma.createFrame();
        root.appendChild(box);
        box.resize(g.width, g.height);
        box.cornerRadius = 16;
        box.fills = [{ type: 'SOLID', color: accent, opacity: 0.06 }];
        box.strokes = [{ type: 'SOLID', color: accent, opacity: 0.42 }];
        box.strokeWeight = 1.25;
        box.dashPattern = [6, 4];
        box.clipsContent = true;

        const header = figma.createRectangle();
        header.resize(g.width, 36);
        header.x = 0;
        header.y = 0;
        header.fills = [{ type: 'SOLID', color: accent, opacity: 0.11 }];
        box.appendChild(header);

        const dot = figma.createRectangle();
        dot.resize(8, 8);
        dot.cornerRadius = 4;
        dot.x = 14;
        dot.y = 14;
        dot.fills = [{ type: 'SOLID', color: accent }];
        box.appendChild(dot);

        const titleNode = figma.createText();
        titleNode.fontName = boldFont || regularFont;
        titleNode.characters = String(grp.title || '分组区域');
        titleNode.fontSize = 12.5;
        titleNode.fills = [{ type: 'SOLID', color: parseHexRGB(board.darkAppearance ? '#F1F2F4' : '#1D1F23') }];
        titleNode.x = 28;
        titleNode.y = 10;
        box.appendChild(titleNode);
        node = box;
      } else if (object.kind === 'paletteStrip') {
        const pal = object.palette || {};
        const swatches = Array.isArray(pal.swatches) && pal.swatches.length ? pal.swatches : [{ hex: '#8B95A1', isLight: false }];
        const strip = figma.createFrame();
        root.appendChild(strip);
        strip.resize(g.width, g.height);
        strip.cornerRadius = 12;
        strip.fills = [];
        strip.clipsContent = true;
        strip.strokes = [{ type: 'SOLID', color: { r: 0, g: 0, b: 0 }, opacity: 0.1 }];
        strip.strokeWeight = 1;

        const sw = g.width / swatches.length;
        swatches.forEach((swatch, idx) => {
          const rect = figma.createRectangle();
          rect.name = swatch.hex || '#888888';
          rect.resize(sw, g.height);
          rect.x = sw * idx;
          rect.y = 0;
          rect.fills = [{ type: 'SOLID', color: parseHexRGB(swatch.hex) }];
          strip.appendChild(rect);

          const label = figma.createText();
          label.fontName = monoFont || regularFont;
          label.characters = String(swatch.hex || '').toUpperCase();
          label.fontSize = 10;
          label.fills = [{ type: 'SOLID', color: swatch.isLight ? { r: 0.12, g: 0.12, b: 0.12 } : { r: 0.96, g: 0.96, b: 0.96 } }];
          label.x = sw * idx + 8;
          label.y = Math.max(6, g.height - 20);
          strip.appendChild(label);
        });
        node = strip;
      } else {
        const placeholder = figma.createText();
        placeholder.fontName = regularFont;
        placeholder.characters = '需要核对\n' + (object.name || '未知对象') + '\n' + (object.warnings || []).join('；');
        placeholder.fontSize = 12;
        placeholder.textAutoResize = 'HEIGHT';
        placeholder.resize(260, 60);
        root.appendChild(placeholder);
        node = placeholder;
      }

      node.name = object.name || object.kind;
      if (g) {
        node.relativeTransform = transform(g, b);
        geometryMap.set(object.id, g);
      }
      if (object.locked && 'locked' in node) node.locked = true;
      node.setPluginData(
        'charkleSource',
        JSON.stringify({ id: object.id, kind: object.kind, geometry: g || null, warnings: object.warnings || [] })
      );
      nodeMap.set(object.id, node);
      imported++;
    }

    // Import connectors (Native FigJam Connectors or Figma Vector arrows)
    for (const conn of board.connectors || []) {
      if (canceled) throw new Error('导入已取消。');
      const fromNode = nodeMap.get(conn.fromNodeID);
      const toNode = nodeMap.get(conn.toNodeID);
      const fromG = geometryMap.get(conn.fromNodeID);
      const toG = geometryMap.get(conn.toNodeID);
      if (!fromNode || !toNode || !fromG || !toG) continue;

      const strokeColor = parseHexRGB(conn.colorHex, { r: 0.45, g: 0.48, b: 0.52 });
      if (figma.editorType === 'figjam' && typeof figma.createConnector === 'function') {
        const c = figma.createConnector();
        c.name = conn.label ? '连线：' + conn.label : '连线';
        c.connectorStart = { endpointNodeId: fromNode.id, magnet: magnetName(conn.fromAnchor) };
        c.connectorEnd = { endpointNodeId: toNode.id, magnet: magnetName(conn.toAnchor) };
        c.connectorLineType = conn.style === 'straight' ? 'STRAIGHT' : conn.style === 'elbow' ? 'ELBOWED' : 'CURVED';
        c.strokes = [{ type: 'SOLID', color: strokeColor }];
        c.strokeWeight = 2;
        if (conn.dashed) c.dashPattern = [7, 5];
        if ('connectorEndStrokeCap' in c) c.connectorEndStrokeCap = 'ARROW_EQUILATERAL';
        if (conn.label && c.text) {
          c.text.fontName = regularFont;
          c.text.characters = String(conn.label);
        }
        root.appendChild(c);
      } else if (typeof figma.createVector === 'function') {
        const ep = resolveConnectorEndpoints(fromG, conn.fromAnchor, toG, conn.toAnchor);
        const sx = ep.start.x - b.x;
        const sy = ep.start.y - b.y;
        const ex = ep.end.x - b.x;
        const ey = ep.end.y - b.y;
        let pathData;
        if (conn.style === 'straight') {
          pathData = `M ${sx} ${sy} L ${ex} ${ey}`;
        } else if (conn.style === 'elbow') {
          const mx = (sx + ex) / 2;
          pathData = `M ${sx} ${sy} L ${mx} ${sy} L ${mx} ${ey} L ${ex} ${ey}`;
        } else {
          const dist = Math.max(40, Math.hypot(ex - sx, ey - sy) * 0.35);
          const dir = (a) => (a === 'top' ? [0, -dist] : a === 'bottom' ? [0, dist] : a === 'leading' ? [-dist, 0] : [dist, 0]);
          const [d1x, d1y] = dir(ep.fromAnchor);
          const [d2x, d2y] = dir(ep.toAnchor);
          pathData = `M ${sx} ${sy} C ${sx + d1x} ${sy + d1y} ${ex + d2x} ${ey + d2y} ${ex} ${ey}`;
        }
        const vec = figma.createVector();
        vec.name = conn.label ? '连线：' + conn.label : '连线';
        vec.vectorPaths = [{ windingRule: 'NONE', data: pathData }];
        vec.strokes = [{ type: 'SOLID', color: strokeColor }];
        vec.strokeWeight = 2;
        if (conn.dashed) vec.dashPattern = [7, 5];
        root.appendChild(vec);

        if (conn.label) {
          const lbl = figma.createText();
          lbl.fontName = regularFont;
          lbl.characters = String(conn.label);
          lbl.fontSize = 11;
          lbl.fills = [{ type: 'SOLID', color: strokeColor }];
          lbl.x = (sx + ex) / 2 - 20;
          lbl.y = (sy + ey) / 2 - 8;
          root.appendChild(lbl);
        }
      }
      imported++;
    }

    // Import Freehand Ink Strokes as editable vector strokes
    for (const stroke of board.inkStrokes || []) {
      if (canceled) throw new Error('导入已取消。');
      if (!Array.isArray(stroke.points) || stroke.points.length < 2) continue;
      if (typeof figma.createVector !== 'function') continue;
      const pts = stroke.points.map(p => ({ x: p.x - b.x, y: p.y - b.y }));
      let d = `M ${pts[0].x} ${pts[0].y}`;
      for (let i = 1; i < pts.length; i++) {
        d += ` L ${pts[i].x} ${pts[i].y}`;
      }
      const vec = figma.createVector();
      vec.name = '手绘批注';
      vec.vectorPaths = [{ windingRule: 'NONE', data: d }];
      vec.strokes = [{ type: 'SOLID', color: parseHexRGB(stroke.colorHex, { r: 0.85, g: 0.36, b: 0.28 }), opacity: safeNumber(stroke.opacity) ? stroke.opacity : 0.92 }];
      vec.strokeWeight = safeNumber(stroke.lineWidth) ? Math.max(1, stroke.lineWidth) : 3.5;
      if ('strokeCap' in vec) vec.strokeCap = 'ROUND';
      if ('strokeJoin' in vec) vec.strokeJoin = 'ROUND';
      root.appendChild(vec);
      imported++;
    }

    if (canceled) throw new Error('导入已取消。');
    const report = finalReport(board, imported, runtimeWarnings);
    root.setPluginData('charkleMigrationReport', JSON.stringify(report));
    root.visible = true;
    figma.currentPage.selection = [root];
    figma.viewport.scrollAndZoomIntoView([root]);
    return { frameId: root.id, importedCount: imported, report };
  } catch (error) {
    root.remove();
    throw error;
  }
}

async function repairAnimations(board) {
  validate(board);
  if (figma.editorType !== 'figjam') throw new Error('原生 GIF 动图补全需要在 FigJam 中运行。');
  const root = figma.currentPage.selection[0];
  if (!root || !root.children || !root.getPluginData('charkleOrigin')) {
    throw new Error('请先选中已导入的整个 Charkle 情绪板区域。');
  }
  let repaired = 0;
  const ids = [];
  for (const object of board.objects.filter(o => o.image && o.image.animation)) {
    const old = root.children.find(n => {
      try {
        return JSON.parse(n.getPluginData('charkleSource')).id === object.id;
      } catch (_) {
        return false;
      }
    });
    if (!old || old.type === 'MEDIA') continue;
    const bytes = await requestAsset(object.image.animation.file);
    let node;
    try {
      node = figma.createGif(figma.createImage(new Uint8Array(bytes)).hash);
      const index = root.children.indexOf(old);
      const position = old.relativeTransform.map(row => row.slice());
      root.insertChild(index, node);
      node.resize(old.width, old.height);
      node.relativeTransform = position;
      node.name = old.name;
      node.setPluginData('charkleSource', old.getPluginData('charkleSource'));
      ids.push(node.id);
      old.remove();
      repaired++;
    } catch (error) {
      if (node && !node.removed) node.remove();
      throw error;
    }
  }
  return { repaired, createdNodeIds: ids, report: JSON.parse(root.getPluginData('charkleMigrationReport') || '{}') };
}

figma.ui.onmessage = async message => {
  if (message.type === 'asset-response') {
    const p = pending.get(message.id);
    if (!p) return;
    clearTimeout(p.timer);
    pending.delete(message.id);
    if (message.error) p.reject(new Error(message.error));
    else p.resolve(message.bytes);
    return;
  }
  if (message.type === 'cancel') {
    canceled = true;
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error('导入已取消。'));
      pending.delete(id);
    }
    return;
  }
  if (message.type === 'repair-animations') {
    if (running) return;
    running = true;
    canceled = false;
    try {
      figma.ui.postMessage({ type: 'repaired', result: await repairAnimations(message.board) });
    } catch (error) {
      figma.ui.postMessage({ type: 'repair-error', error: String(error.message || error) });
    } finally {
      running = false;
    }
    return;
  }
  if (message.type !== 'import' || running) return;
  running = true;
  canceled = false;
  try {
    const result = await importBoard(message.board, message.allowReview);
    figma.ui.postMessage({ type: 'done', result });
  } catch (error) {
    figma.ui.postMessage({ type: 'error', error: String(error.message || error) });
  } finally {
    running = false;
  }
};
