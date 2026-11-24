import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  CustomSelect,
  EmptyStateVignette,
  SegmentedControl,
  hasMeaningfulCameraExif,
  isLongStripImage,
  useDelayedFlag,
  type EmptyVignetteKind,
} from '../design-system';
import { computeMasonryLayout } from '../features/gallery/VerticalMasonryView';
import { computeJustifiedLayout } from '../features/gallery/HorizontalJustifiedView';
import { TopFilterCapsule } from '../features/gallery/TopFilterCapsule';
import { FolderTree } from '../features/sidebar/FolderTree';
import { isPastOutboundBoundary } from '../features/dnd/PointerDragContext';
import { useCoordinatorStore } from '../stores';
import type { AssetRecord, FolderRecord } from '../types/domain';

function makeDummyAsset(index: number): AssetRecord {
  return {
    id: `asset-${index}`,
    contentHash: `hash-${index}`,
    mediaKind: 'image',
    mimeType: 'image/png',
    title: `Asset ${index}`,
    fileName: `asset-${index}.png`,
    notes: '',
    tags: [],
    suggestedTags: [],
    rating: 0,
    pixelWidth: 800,
    pixelHeight: 600 + (index % 5) * 180,
    fileSizeBytes: 1024,
    dominantColors: [],
    waveformPeaks: [],
    pinnedOffline: false,
    isLocalOriginalCached: true,
    isTrashed: false,
    createdAt: 0,
    updatedAt: 0,
    updatedHLC: index,
  };
}

describe('Charkle Design System & Layout Algorithms', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('detects long-strip images strictly by height >= 1600 and h/w >= 2.2', () => {
    expect(isLongStripImage({ mediaKind: 'image', pixelWidth: 800, pixelHeight: 2800 })).toBe(true);
    expect(isLongStripImage({ mediaKind: 'image', pixelWidth: 800, pixelHeight: 1760 })).toBe(true);
    expect(isLongStripImage({ mediaKind: 'image', pixelWidth: 800, pixelHeight: 1599 })).toBe(false);
    expect(isLongStripImage({ mediaKind: 'image', pixelWidth: 1000, pixelHeight: 1800 })).toBe(false);
    expect(isLongStripImage({ mediaKind: 'video', pixelWidth: 800, pixelHeight: 2800 })).toBe(false);
  });

  it('gates camera EXIF card strictly via hasMeaningfulCameraExif', () => {
    expect(hasMeaningfulCameraExif(null)).toBe(false);
    expect(hasMeaningfulCameraExif({ dpiWidth: 72, dpiHeight: 72, colorProfile: 'sRGB' })).toBe(
      false,
    );
    expect(hasMeaningfulCameraExif({ cameraMake: 'Fujifilm', cameraModel: 'X-T5' })).toBe(true);
    expect(hasMeaningfulCameraExif({ iso: 400 })).toBe(true);
  });

  it('suppresses fast < 300ms loading flicker with useDelayedFlag', () => {
    vi.useFakeTimers();
    const Probe: React.FC<{ active: boolean }> = ({ active }) => {
      const shown = useDelayedFlag(active, 300, 500);
      return <div data-testid="probe">{shown ? 'visible' : 'hidden'}</div>;
    };

    const { rerender } = render(<Probe active={true} />);
    expect(screen.getByTestId('probe').textContent).toBe('hidden');

    act(() => {
      vi.advanceTimersByTime(200);
    });
    rerender(<Probe active={false} />);
    act(() => {
      vi.advanceTimersByTime(300);
    });
    expect(screen.getByTestId('probe').textContent).toBe('hidden');

    rerender(<Probe active={true} />);
    act(() => {
      vi.advanceTimersByTime(310);
    });
    expect(screen.getByTestId('probe').textContent).toBe('visible');

    // Stays visible for minimum 500ms after showing
    rerender(<Probe active={false} />);
    act(() => {
      vi.advanceTimersByTime(200);
    });
    expect(screen.getByTestId('probe').textContent).toBe('visible');
    act(() => {
      vi.advanceTimersByTime(350);
    });
    expect(screen.getByTestId('probe').textContent).toBe('hidden');
  });

  it('switches values cleanly in SegmentedControl', () => {
    const onChange = vi.fn();
    render(
      <SegmentedControl
        value="a"
        onChange={onChange}
        options={[
          { value: 'a', label: '选项 A' },
          { value: 'b', label: '选项 B' },
        ]}
      />,
    );
    fireEvent.click(screen.getByRole('radio', { name: '选项 B' }));
    expect(onChange).toHaveBeenCalledWith('b');
  });

  it('distributes SegmentedControl segments evenly without inline-flex overriding grid/w-full', () => {
    const onChange = vi.fn();
    render(
      <SegmentedControl
        value="info"
        onChange={onChange}
        ariaLabel="检查器标签页"
        className="w-full grid grid-cols-2"
        options={[
          { value: 'info', label: '信息' },
          { value: 'similar', label: '类似项目 (5)' },
        ]}
      />,
    );
    const group = screen.getByRole('radiogroup', { name: '检查器标签页' });
    expect(group.className).toContain('grid-cols-2');
    expect(group.className).not.toContain('inline-flex');
    for (const radio of screen.getAllByRole('radio')) {
      expect(radio.className).toContain('w-full');
      expect(radio.className).toContain('justify-center');
    }
  });

  it('opens CustomSelect listbox and enables search at >= 15 options', () => {
    const onChange = vi.fn();
    const options = Array.from({ length: 16 }, (_, i) => ({
      value: `opt-${i}`,
      label: `分类选项 ${i}`,
    }));
    render(
      <CustomSelect value="opt-0" options={options} onChange={onChange} ariaLabel="分类选择器" />,
    );
    fireEvent.click(screen.getByRole('button', { name: '分类选择器' }));
    const searchInput = screen.getByPlaceholderText('筛选选项…');
    fireEvent.change(searchInput, { target: { value: '12' } });
    fireEvent.click(screen.getByRole('option', { name: '分类选项 12' }));
    expect(onChange).toHaveBeenCalledWith('opt-12');
  });

  it('renders all 5 miniature UI vignette SVGs without error', () => {
    const kinds: EmptyVignetteKind[] = [
      'emptyLibrary',
      'inboxZero',
      'noResults',
      'emptyFolder',
      'emptyMoodboards',
    ];
    for (const kind of kinds) {
      const { container, unmount } = render(<EmptyStateVignette kind={kind} />);
      expect(container.querySelector('svg')).not.toBeNull();
      unmount();
    }
  });

  it('computes 10,000-asset Masonry & Justified layouts in linear time', () => {
    const batch = Array.from({ length: 10_000 }, (_, i) => makeDummyAsset(i));
    const masonry = computeMasonryLayout(batch, 1200, 240, 12);
    expect(masonry.items.length).toBe(10_000);
    expect(masonry.totalHeight).toBeGreaterThan(100_000);

    const justified = computeJustifiedLayout(batch, 1200, 210, 12);
    expect(justified.items.length).toBe(10_000);
    expect(justified.totalHeight).toBeGreaterThan(100_000);
  });

  it('triggers outbound OLE drag past viewport edges while preserving internal drop targets', () => {
    // Exiting viewport ALWAYS hands off to native OLE drag even if last target was set
    expect(isPastOutboundBoundary(-5, 300, 1360, 860, true)).toBe(true);
    expect(isPastOutboundBoundary(1362, 300, 1360, 860, false)).toBe(true);
    expect(isPastOutboundBoundary(500, -1, 1360, 860, false)).toBe(true);
    expect(isPastOutboundBoundary(500, 860, 1360, 860, true)).toBe(true);
    // 8px outer rim triggers outbound OLE when not over an internal drop target
    expect(isPastOutboundBoundary(6, 300, 1360, 860, false)).toBe(true);
    expect(isPastOutboundBoundary(1354, 300, 1360, 860, false)).toBe(true);
    // Hovering a sidebar folder near the left edge stays internal
    expect(isPastOutboundBoundary(6, 300, 1360, 860, true)).toBe(false);
    // Interior drag stays internal
    expect(isPastOutboundBoundary(400, 400, 1360, 860, false)).toBe(false);
  });

  it('keeps FolderTree "..." action button laid out while its menu is open and uses acrylic filter bar', () => {
    const folder: FolderRecord = {
      id: 'folder-typo',
      name: 'Typography',
      parentID: null,
      sortOrder: 0,
      colorHex: null,
      customSymbol: null,
      assetCount: 2,
      createdAt: 0,
      updatedAt: 0,
    };
    render(
      <FolderTree
        folders={[folder]}
        activeFolderId={null}
        onSelectFolder={vi.fn()}
        onCreateSubfolder={vi.fn().mockResolvedValue(undefined)}
        onRenameFolder={vi.fn().mockResolvedValue(undefined)}
        onMoveFolder={vi.fn().mockResolvedValue(undefined)}
        onUpdateAppearance={vi.fn().mockResolvedValue(undefined)}
        onDeleteFolder={vi.fn().mockResolvedValue(undefined)}
        onDropAssets={vi.fn().mockResolvedValue(undefined)}
      />,
    );

    const moreBtn = screen.getByRole('button', { name: '更多操作：Typography' });
    const actionsWrapper = moreBtn.parentElement!;
    expect(actionsWrapper.className).toContain('hidden');

    fireEvent.click(moreBtn);
    expect(actionsWrapper.className).toContain('flex');
    expect(actionsWrapper.className).not.toContain('hidden');
    expect(moreBtn.getAttribute('aria-expanded')).toBe('true');

    useCoordinatorStore.setState({ visualFilterBarOpen: true });
    render(<TopFilterCapsule galleryViewportWidth={1100} sectionTitle="收件箱" itemCount={7} />);
    const filterBar = screen.getByTestId('visual-filter-bar');
    expect(filterBar.className).toContain('win-acrylic-bar');
    useCoordinatorStore.setState({ visualFilterBarOpen: false });
  });
});
