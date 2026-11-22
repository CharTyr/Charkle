import { describe, expect, it } from 'vitest';
import {
  bestDeltaE,
  deltaE,
  deltaE2000,
  isLightHex,
  labFromHex,
  labToHex,
  labToSRGB,
  parseHex,
  sRGBToLab,
} from '../src/color/lab.js';

describe('LabColor & color math', () => {
  it('parses valid 6-digit hex strings and rejects invalid ones', () => {
    expect(parseHex('#3b82f6')).toEqual({
      r: 0x3b / 255,
      g: 0x82 / 255,
      b: 0xf6 / 255,
      hex: '#3B82F6',
    });
    expect(parseHex('  ffffff  ')).toEqual({ r: 1, g: 1, b: 1, hex: '#FFFFFF' });
    expect(parseHex('#123')).toBeNull();
    expect(parseHex('zzzzzz')).toBeNull();
  });

  it('converts sRGB <-> CIELAB accurately and round-trips hex values', () => {
    const white = labFromHex('#FFFFFF');
    expect(white.l).toBeCloseTo(100, 2);
    expect(white.a).toBeCloseTo(0, 2);
    expect(white.b).toBeCloseTo(0, 2);

    const black = labFromHex('#000000');
    expect(black.l).toBeCloseTo(0, 2);
    expect(black.a).toBeCloseTo(0, 2);
    expect(black.b).toBeCloseTo(0, 2);

    const samples = ['#3B82F6', '#E05A47', '#10B981', '#F59E0B', '#18181B', '#F6F6F5'];
    for (const hex of samples) {
      const lab = labFromHex(hex);
      expect(lab.hex).toBe(hex);
      expect(labToHex(lab.l, lab.a, lab.b)).toBe(hex);
      const rgb = labToSRGB(lab.l, lab.a, lab.b);
      const back = sRGBToLab(rgb.r, rgb.g, rgb.b);
      expect(deltaE(lab, back)).toBeLessThan(0.01);
    }
  });

  it('falls back to neutral gray on invalid hex matching Swift LabColor.fromHex', () => {
    const invalid = labFromHex('not-a-color', 0.42);
    expect(invalid).toEqual({ hex: '#808080', l: 53.59, a: 0, b: 0, proportion: 0.42 });
  });

  it('computes CIE76 deltaE and CIEDE2000 accurately (Sharma et al. 2005 reference pair)', () => {
    const blue1 = labFromHex('#3B82F6');
    const blue2 = labFromHex('#2563EB');
    const red = labFromHex('#EF4444');
    expect(deltaE(blue1, blue1)).toBe(0);
    expect(deltaE(blue1, blue2)).toBeCloseTo(18.9753, 3);
    expect(deltaE(blue1, blue2)).toBeLessThan(24);
    expect(deltaE(blue1, red)).toBeGreaterThan(60);

    // Sharma, Wu, Dalal (2005) Table 1 pair #1: (50.0000, 2.6772, -79.7751) vs (50.0000, 0.0000, -82.7485) -> 2.0425
    const d00 = deltaE2000(
      { l: 50.0, a: 2.6772, b: -79.7751 },
      { l: 50.0, a: 0.0, b: -82.7485 },
    );
    expect(d00).toBeCloseTo(2.0425, 4);

    // Identical colors yield 0 in CIEDE2000
    expect(deltaE2000(blue1, blue1)).toBeCloseTo(0, 8);
  });

  it('finds bestDeltaE across palettes and evaluates isLightHex contrast threshold', () => {
    const target = labFromHex('#2563EB');
    expect(bestDeltaE(target, [])).toBeNull();
    const d = bestDeltaE(target, [labFromHex('#EF4444'), labFromHex('#3B82F6')]);
    expect(d).not.toBeNull();
    expect(d!).toBeCloseTo(deltaE(target, labFromHex('#3B82F6')), 6);

    expect(isLightHex('#FFFFFF')).toBe(true);
    expect(isLightHex('#F6F6F5')).toBe(true);
    expect(isLightHex('#FACC15')).toBe(true);
    expect(isLightHex('#18181B')).toBe(false);
    expect(isLightHex('#2563EB')).toBe(false);
    expect(isLightHex('invalid')).toBe(false);
  });
});
