import { describe, expect, it } from 'vitest';
import { EditorialLayoutSolver } from '../src/layout/editorial.js';
import { createDefaultAssetRecord } from '../src/models/core.js';
import type { AssetRecord } from '../src/models/core.js';
import {
  createDefaultAutoLayoutConfig,
  createDefaultMoodboardDocument,
  rectMaxX,
  rectMaxY,
  rectMinX,
  rectMinY,
} from '../src/models/moodboard.js';
import type { BoardNode, BoardRect } from '../src/models/moodboard.js';

describe('EditorialLayoutSolver', () => {
  function makeFixture(count = 12) {
    const assetsByID: Record<string, AssetRecord> = {};
    const nodes: BoardNode[] = [];
    const now = '2026-11-22T12:00:00.000Z';

    for (let i = 0; i < count; i++) {
      const id = `00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`;
      const assetId = `AAAAAAAA-0000-4000-8000-${String(i + 1).padStart(12, '0')}`;
      assetsByID[assetId] = createDefaultAssetRecord({
        id: assetId,
        title: `M${i}`,
        fileName: `m${i}.jpg`,
        mediaKind: 'image',
        pixelWidth: 1200,
        pixelHeight: 900,
      });
      nodes.push({
        id,
        kind: {
          type: 'assetRef',
          assetID: assetId,
          crop: null,
          weight: i === 0 ? 2 : 1,
          autoplayLoop: false,
        },
        frame: { x: i * 40, y: 40, width: 200, height: 150 },
        zIndex: i,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: i,
        updatedAt: now,
      });
    }
    return { assetsByID, nodes };
  }

  it('produces distinct geometry across magazine, balanced, and compact styles with magazine Hero 2-col span', () => {
    const { assetsByID, nodes } = makeFixture(12);

    const mag = EditorialLayoutSolver.solve(
      nodes,
      createDefaultAutoLayoutConfig({ style: 'magazine' }),
      1100,
      assetsByID,
    );
    const bal = EditorialLayoutSolver.solve(
      nodes,
      createDefaultAutoLayoutConfig({ style: 'balanced' }),
      1100,
      assetsByID,
    );
    const cmp = EditorialLayoutSolver.solve(
      nodes,
      createDefaultAutoLayoutConfig({ style: 'compact' }),
      1100,
      assetsByID,
    );

    expect(mag.columnCount).toBe(3);
    expect(bal.columnCount).toBe(4);
    expect(cmp.columnCount).toBeGreaterThanOrEqual(5);
    expect(mag.columnCount).toBeLessThan(bal.columnCount);
    expect(bal.columnCount).toBeLessThan(cmp.columnCount);
    expect(mag.columnWidth).toBeGreaterThan(bal.columnWidth);
    expect(bal.columnWidth).toBeGreaterThan(cmp.columnWidth);

    // First node in magazine mode with 3 columns spans 2 columns + styleSpacing (26)
    const heroFrame = mag.frames[nodes[0].id];
    expect(heroFrame.width).toBeCloseTo(mag.columnWidth * 2 + 26, 6);

    // Node 1 is single-column width
    const regularFrame = mag.frames[nodes[1].id];
    expect(regularFrame.width).toBeCloseTo(mag.columnWidth, 6);
  });

  it('handles full-width groupFrame, paletteStrip, and note nodes cleanly', () => {
    const { assetsByID, nodes } = makeFixture(3);
    const now = '2026-11-22T12:00:00.000Z';
    const mixed: BoardNode[] = [
      {
        id: 'F0000000-0000-4000-8000-000000000001',
        kind: { type: 'groupFrame', title: 'Typography', tint: 'sand' },
        frame: { x: 0, y: 0, width: 400, height: 64 },
        zIndex: 0,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: 0,
        updatedAt: now,
      },
      ...nodes,
      {
        id: 'F0000000-0000-4000-8000-000000000002',
        kind: { type: 'note', title: 'Direction', text: 'Warm editorial grit with crisp sans type.', style: 'paper', fontSize: 15 },
        frame: { x: 0, y: 0, width: 220, height: 140 },
        zIndex: 4,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: 10,
        updatedAt: now,
      },
      {
        id: 'F0000000-0000-4000-8000-000000000003',
        kind: { type: 'paletteStrip', colors: [], autoSyncWithBoard: true },
        frame: { x: 0, y: 0, width: 800, height: 76 },
        zIndex: 5,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: 11,
        updatedAt: now,
      },
    ];

    const res = EditorialLayoutSolver.solve(
      mixed,
      createDefaultAutoLayoutConfig({ style: 'balanced' }),
      1000,
      assetsByID,
    );
    expect(res.orderedNodeIDs.length).toBe(6);
    expect(res.frames['F0000000-0000-4000-8000-000000000001'].width).toBeCloseTo(1000 - 56, 4);
    expect(res.frames['F0000000-0000-4000-8000-000000000003'].height).toBe(76);
    expect(res.frames['F0000000-0000-4000-8000-000000000002'].height).toBeGreaterThanOrEqual(124);
  });

  it('keeps all child nodes strictly inside groupRect during reflowNodesInsideGroupFrame', () => {
    const { assetsByID, nodes } = makeFixture(6);
    const groupRect: BoardRect = { x: 100, y: 100, width: 640, height: 340 };

    const reflowed = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
      groupRect,
      nodes,
      assetsByID,
    );
    expect(Object.keys(reflowed)).toHaveLength(6);

    for (const r of Object.values(reflowed)) {
      expect(rectMinX(r)).toBeGreaterThanOrEqual(rectMinX(groupRect));
      expect(rectMinY(r)).toBeGreaterThanOrEqual(rectMinY(groupRect));
      expect(rectMaxX(r)).toBeLessThanOrEqual(rectMaxX(groupRect) + 1.0);
      expect(rectMaxY(r)).toBeLessThanOrEqual(rectMaxY(groupRect) + 1.0);
      expect(r.width).toBeGreaterThan(20);
      expect(r.height).toBeGreaterThan(20);
    }
  });

  it('freezes autoEditorial into freeform without shifting frames and tidies freeform nodes', () => {
    const { assetsByID, nodes } = makeFixture(4);
    const doc = createDefaultMoodboardDocument({
      id: 'BBBBBBBB-0000-4000-8000-000000000001',
      title: 'Test Board',
      nodes,
      mode: { type: 'autoEditorial', config: createDefaultAutoLayoutConfig({ style: 'balanced' }) },
    });

    const solved = EditorialLayoutSolver.solve(
      nodes,
      createDefaultAutoLayoutConfig({ style: 'balanced' }),
      1040,
      assetsByID,
    );
    const frozen = EditorialLayoutSolver.freezeIntoFreeform(doc, 1040, assetsByID);
    expect(frozen.mode).toEqual({ type: 'freeform' });
    for (const node of frozen.nodes) {
      expect(node.frame).toEqual(solved.frames[node.id]);
    }

    const tidied = EditorialLayoutSolver.tidyNodesInFreeform(frozen, new Set(), assetsByID);
    expect(tidied.nodes).toHaveLength(4);
  });
});
