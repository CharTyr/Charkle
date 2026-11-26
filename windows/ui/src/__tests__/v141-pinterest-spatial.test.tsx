import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { PinterestWorkspace } from '../features/pinterest/PinterestWorkspace';
import {
  PinterestSpatialLayout,
  cameraScreenToWorld,
  cameraZoomAt,
  createCenteredCamera,
  pinAspectRatio,
  rectsIntersect,
} from '../features/pinterest/spatialLayout';
import { useCoordinatorStore, useLibraryStore, usePinterestStore } from '../stores';
import type { PinterestPin } from '../types/domain';

function makePins(count: number, offset = 0): PinterestPin[] {
  return Array.from({ length: count }, (_, idx) => {
    const n = idx + offset;
    return {
      id: `pin_${n}`,
      title: `Design Study ${n}`,
      description: `Reference ${n}`,
      authorName: 'Atelier Test',
      authorUsername: 'atelier_test',
      authorAvatarURL: null,
      boardName: 'Editorial',
      boardID: 'board_1',
      domain: 'pinterest.com',
      linkURL: null,
      pinPageURL: `https://www.pinterest.com/pin/500000${n}/`,
      originalURL: `https://i.pinimg.com/originals/p/${n}.jpg`,
      previewURL: `https://i.pinimg.com/736x/p/${n}.jpg`,
      thumbnailURL: `https://i.pinimg.com/236x/p/${n}.jpg`,
      videoURL: null,
      pixelWidth: 800,
      pixelHeight: 900 + ((n * 173) % 700),
      dominantColorHex: '#334155',
    };
  });
}

describe('v1.4.1 Pinterest Spatial Layout & Camera Math', () => {
  it('places cards non-overlapping across 4 quadrants with 0px append shift and directional prefetch', () => {
    const layout = new PinterestSpatialLayout(220, 16);
    const first = layout.append(makePins(40, 0));
    expect(first).toHaveLength(40);
    const savedFrames = new Map(first.map((c) => [c.id, { ...c.frame }]));

    layout.append(makePins(50, 40));
    expect(layout.cards).toHaveLength(90);

    // 1. 0px shift on append
    for (const card of layout.cards.slice(0, 40)) {
      expect(card.frame).toEqual(savedFrames.get(card.id));
    }

    // 2. Zero overlapping cards
    for (let i = 0; i < layout.cards.length; i += 1) {
      for (let j = i + 1; j < layout.cards.length; j += 1) {
        expect(rectsIntersect(layout.cards[i].frame, layout.cards[j].frame)).toBe(false);
      }
    }

    // 3. Spans all 4 quadrants around origin
    const b = layout.contentBounds;
    expect(b.x).toBeLessThan(0);
    expect(b.x + b.width).toBeGreaterThan(0);
    expect(b.y).toBeLessThan(0);
    expect(b.y + b.height).toBeGreaterThan(0);

    // 4. Predictive directional prefetch prioritizes incoming travel direction
    const vp = { x: -220, y: -180, width: 440, height: 360 };
    const eastward = layout.predictivePrefetchCards(vp, { width: 560, height: 0 }, 720, 12);
    expect(eastward.length).toBeGreaterThan(0);
    for (const card of eastward) {
      expect(rectsIntersect(card.frame, vp)).toBe(false);
    }
    const avgEastX =
      eastward.reduce((sum, c) => sum + c.frame.x + c.frame.width * 0.5, 0) / eastward.length;
    expect(avgEastX).toBeGreaterThan(0);
  });

  it('keeps anchor world coordinate stationary within <0.001px during cursor-anchored zoom', () => {
    const cam = createCenteredCamera({ width: 1200, height: 800 }, 1.0);
    const anchor = { x: 840, y: 260 };
    const before = cameraScreenToWorld(cam, anchor);
    const zoomed = cameraZoomAt(cam, 1.85, anchor);
    const after = cameraScreenToWorld(zoomed, anchor);

    expect(Math.abs(before.x - after.x)).toBeLessThan(0.001);
    expect(Math.abs(before.y - after.y)).toBeLessThan(0.001);
  });
});

describe('v1.4.1 Pinterest Workspace, Tray Cart, Detail Overlay & Board Batch Import', () => {
  let transport: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    transport = new InMemoryMockTransport(true);
    setTransport(transport);
    useCoordinatorStore.setState({ destination: { type: 'pinterest' }, toasts: [] });
    usePinterestStore.getState().getSpatialLayout().reset();
    usePinterestStore.setState({
      sessionState: 'unknown',
      account: null,
      boards: [],
      cards: [],
      collectedPins: [],
      collectedPinIds: {},
      traySelectedPinIds: {},
      isTrayExpanded: false,
      isQuickCollectMode: false,
      detailStack: [],
      activeDetailPin: null,
      activeSimilarPins: [],
      lightboxOpen: false,
      boardImportModalOpen: false,
      lastBoardImportReport: null,
    });
  });

  afterEach(() => {
    cleanup();
  });

  it('hides + badge in Browse mode, reveals + in Fast-Pick mode, supports horizontal aspect-preserving tray, detail modal & lightbox', async () => {
    render(<PinterestWorkspace />);

    await waitFor(() => {
      expect(usePinterestStore.getState().cards.length).toBeGreaterThan(0);
    });

    const firstPin = usePinterestStore.getState().cards[0].pin;

    // Browse mode: no `+` badge on uncollected card
    expect(screen.queryByTestId(`pin-badge-add-${firstPin.id}`)).toBeNull();

    // Switch to Fast-Pick mode via floating icon-only pill
    fireEvent.click(screen.getByTestId('pinterest-mode-fastpick'));
    expect(usePinterestStore.getState().isQuickCollectMode).toBe(true);
    expect(screen.getByTestId(`pin-badge-add-${firstPin.id}`)).toBeTruthy();

    // Click `+` to collect first pin into shopping cart tray
    fireEvent.click(screen.getByTestId(`pin-badge-add-${firstPin.id}`));
    expect(usePinterestStore.getState().collectedPins).toHaveLength(1);
    expect(screen.getByTestId('pinterest-collection-tray')).toBeTruthy();

    // Verify localStorage persistence
    const saved = JSON.parse(localStorage.getItem('charkle.pinterest.collectionTray.v1') || '[]');
    expect(saved).toHaveLength(1);
    expect(saved[0].id).toBe(firstPin.id);

    // Expand shopping-cart tray and verify aspect-preserving width (NOT 1:1 square crop!)
    fireEvent.click(screen.getByTestId('pinterest-tray-expand-btn'));
    const trayCard = screen.getByTestId(`pinterest-tray-card-${firstPin.id}`);
    const expectedWidth = Math.min(260, Math.max(76, Math.round(146 * pinAspectRatio(firstPin))));
    expect(trayCard.style.height).toBe('146px');
    expect(trayCard.style.width).toBe(`${expectedWidth}px`);

    // Clicking tray card opens floating Pin Detail overlay with Similar Pins
    fireEvent.click(screen.getByTestId(`pinterest-tray-open-detail-${firstPin.id}`));
    await waitFor(() => {
      expect(screen.getByTestId('pinterest-pin-detail-modal')).toBeTruthy();
      expect(usePinterestStore.getState().activeSimilarPins.length).toBeGreaterThan(0);
    });

    // Clicking hero artwork opens full-resolution lightbox; Escape closes lightbox first
    fireEvent.click(screen.getByTestId('pinterest-detail-hero-image'));
    expect(screen.getByTestId('pinterest-pin-lightbox')).toBeTruthy();
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByTestId('pinterest-pin-lightbox')).toBeNull();
      expect(screen.getByTestId('pinterest-pin-detail-modal')).toBeTruthy();
    });
    // Second Escape closes detail modal
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByTestId('pinterest-pin-detail-modal')).toBeNull();
    });

    // Selective removal from tray works cleanly
    fireEvent.click(screen.getByTestId('pinterest-tray-remove-selected-btn'));
    expect(usePinterestStore.getState().collectedPins).toHaveLength(0);
  });

  it('batch imports Pinterest boards into Charkle folders and reports imported/skipped counts', async () => {
    await useLibraryStore.getState().bootstrap({ type: 'allItems' });
    render(<PinterestWorkspace />);

    await waitFor(() => {
      expect(usePinterestStore.getState().boards.length).toBe(2);
    });

    fireEvent.click(screen.getByTestId('pinterest-open-board-import-btn'));
    expect(screen.getByTestId('pinterest-board-import-modal')).toBeTruthy();

    fireEvent.click(screen.getByTestId('pinterest-start-board-import-btn'));

    await waitFor(() => {
      expect(screen.getByTestId('pinterest-board-import-report')).toBeTruthy();
    });

    const report = usePinterestStore.getState().lastBoardImportReport;
    expect(report).not.toBeNull();
    expect(report?.wasCancelled).toBe(false);
    expect(report?.importedAssetCount).toBeGreaterThan(0);
    expect(report?.createdOrReusedFolderIDs.length).toBeGreaterThanOrEqual(3); // Pinterest root + 2 board subfolders

    // Second incremental run skips duplicates
    fireEvent.click(screen.getByTestId('pinterest-start-board-import-btn'));
    await waitFor(() => {
      expect(usePinterestStore.getState().lastBoardImportReport?.importedAssetCount).toBe(0);
      expect(
        usePinterestStore.getState().lastBoardImportReport?.skippedDuplicateCount,
      ).toBeGreaterThan(0);
    });
  });
});
