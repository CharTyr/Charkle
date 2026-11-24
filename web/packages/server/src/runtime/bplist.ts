/**
 * Minimal, pure-JavaScript Apple Binary Property List (`bplist00`) reader & writer.
 * Runtime-agnostic (zero `node:*` imports) — runs identically on Node.js and Cloudflare Workers.
 * Used for:
 * - macOS binary `.webloc` bookmark parsing (`P0-04`)
 * - macOS ↔ Web `/.charkle/embeddings/shard-<prefix>.bin` binary plist interop (`P0-11`)
 */

export type PlistValue =
  | null
  | boolean
  | number
  | string
  | Uint8Array
  | PlistValue[]
  | { [key: string]: PlistValue };

const MAGIC = new Uint8Array([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30]); // "bplist00"

export function isBinaryPlist(bytes: Uint8Array): boolean {
  if (bytes.byteLength < 40) return false;
  for (let i = 0; i < MAGIC.length; i++) {
    if (bytes[i] !== MAGIC[i]) return false;
  }
  return true;
}

function readUIntBE(view: DataView, offset: number, size: number): number {
  let val = 0;
  for (let i = 0; i < size; i++) {
    val = val * 256 + view.getUint8(offset + i);
  }
  return val;
}

function readIntBE(view: DataView, offset: number, size: number): number {
  if (size === 1) return view.getUint8(offset); // Apple bplist stores 1-byte ints unsigned
  if (size === 2) return view.getUint16(offset, false);
  if (size === 4) return view.getUint32(offset, false);
  if (size === 8) {
    const hi = view.getInt32(offset, false);
    const lo = view.getUint32(offset + 4, false);
    return hi * 0x100000000 + lo;
  }
  return readUIntBE(view, offset, size);
}

export function parseBinaryPlist(bytes: Uint8Array): PlistValue {
  if (!isBinaryPlist(bytes)) {
    throw new Error('Invalid binary plist header (expected bplist00).');
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const trailerOffset = bytes.byteLength - 32;
  const offsetIntSize = view.getUint8(trailerOffset + 6);
  const objectRefSize = view.getUint8(trailerOffset + 7);
  const numObjects = readUIntBE(view, trailerOffset + 8, 8);
  const topObject = readUIntBE(view, trailerOffset + 16, 8);
  const offsetTableOffset = readUIntBE(view, trailerOffset + 24, 8);

  if (
    offsetIntSize < 1 ||
    offsetIntSize > 8 ||
    objectRefSize < 1 ||
    objectRefSize > 8 ||
    numObjects > 1_000_000 ||
    offsetTableOffset < 8 ||
    offsetTableOffset + numObjects * offsetIntSize > trailerOffset
  ) {
    throw new Error('Corrupt binary plist trailer.');
  }

  const offsets = new Array<number>(numObjects);
  for (let i = 0; i < numObjects; i++) {
    offsets[i] = readUIntBE(view, offsetTableOffset + i * offsetIntSize, offsetIntSize);
  }

  const cache = new Map<number, PlistValue>();
  const visiting = new Set<number>();

  const readCount = (lowNibble: number, pos: number): { count: number; nextPos: number } => {
    if (lowNibble !== 0x0f) {
      return { count: lowNibble, nextPos: pos };
    }
    const marker = view.getUint8(pos);
    if ((marker & 0xf0) !== 0x10) {
      throw new Error('Invalid binary plist extended length marker.');
    }
    const byteCount = 1 << (marker & 0x0f);
    const count = readUIntBE(view, pos + 1, byteCount);
    return { count, nextPos: pos + 1 + byteCount };
  };

  const decodeObject = (index: number): PlistValue => {
    if (index < 0 || index >= numObjects) {
      throw new Error(`Binary plist object index out of range: ${index}`);
    }
    if (cache.has(index)) return cache.get(index)!;
    if (visiting.has(index)) {
      throw new Error('Cyclic reference in binary plist.');
    }
    visiting.add(index);

    const pos = offsets[index];
    if (pos < 8 || pos >= offsetTableOffset) {
      throw new Error(`Binary plist object offset out of range: ${pos}`);
    }
    const marker = view.getUint8(pos);
    const type = (marker & 0xf0) >> 4;
    const info = marker & 0x0f;

    let value: PlistValue;
    switch (type) {
      case 0x0: {
        if (info === 0x0) value = null;
        else if (info === 0x8) value = false;
        else if (info === 0x9) value = true;
        else value = null;
        break;
      }
      case 0x1: {
        const size = 1 << info;
        value = readIntBE(view, pos + 1, size);
        break;
      }
      case 0x2: {
        const size = 1 << info;
        if (size === 4) value = view.getFloat32(pos + 1, false);
        else if (size === 8) value = view.getFloat64(pos + 1, false);
        else throw new Error(`Unsupported binary plist real size: ${size}`);
        break;
      }
      case 0x3: {
        // Apple Cocoa date (seconds since 2001-01-01)
        value = view.getFloat64(pos + 1, false);
        break;
      }
      case 0x4: {
        const { count, nextPos } = readCount(info, pos + 1);
        value = bytes.slice(nextPos, nextPos + count);
        break;
      }
      case 0x5: {
        const { count, nextPos } = readCount(info, pos + 1);
        let str = '';
        for (let i = 0; i < count; i++) {
          str += String.fromCharCode(bytes[nextPos + i]);
        }
        value = str;
        break;
      }
      case 0x6: {
        const { count, nextPos } = readCount(info, pos + 1);
        let str = '';
        for (let i = 0; i < count; i++) {
          str += String.fromCharCode(view.getUint16(nextPos + i * 2, false));
        }
        value = str;
        break;
      }
      case 0x8: {
        const size = info + 1;
        value = readUIntBE(view, pos + 1, size);
        break;
      }
      case 0xa: {
        const { count, nextPos } = readCount(info, pos + 1);
        const arr: PlistValue[] = [];
        for (let i = 0; i < count; i++) {
          const ref = readUIntBE(view, nextPos + i * objectRefSize, objectRefSize);
          arr.push(decodeObject(ref));
        }
        value = arr;
        break;
      }
      case 0xd: {
        const { count, nextPos } = readCount(info, pos + 1);
        const dict: Record<string, PlistValue> = {};
        const valBase = nextPos + count * objectRefSize;
        for (let i = 0; i < count; i++) {
          const keyRef = readUIntBE(view, nextPos + i * objectRefSize, objectRefSize);
          const valRef = readUIntBE(view, valBase + i * objectRefSize, objectRefSize);
          const key = decodeObject(keyRef);
          if (typeof key === 'string') {
            dict[key] = decodeObject(valRef);
          }
        }
        value = dict;
        break;
      }
      default:
        throw new Error(`Unsupported binary plist marker type: 0x${type.toString(16)}`);
    }

    visiting.delete(index);
    cache.set(index, value);
    return value;
  };

  return decodeObject(topObject);
}

function isPureAscii(str: string): boolean {
  for (let i = 0; i < str.length; i++) {
    if (str.charCodeAt(i) > 0x7f) return false;
  }
  return true;
}

function writeLengthHeader(out: number[], typeHighNibble: number, count: number): void {
  if (count < 15) {
    out.push(typeHighNibble | count);
    return;
  }
  out.push(typeHighNibble | 0x0f);
  if (count <= 0xff) {
    out.push(0x10, count);
  } else if (count <= 0xffff) {
    out.push(0x11, (count >>> 8) & 0xff, count & 0xff);
  } else {
    out.push(
      0x12,
      (count >>> 24) & 0xff,
      (count >>> 16) & 0xff,
      (count >>> 8) & 0xff,
      count & 0xff,
    );
  }
}

function pushUIntBE(out: number[], value: number, size: number): void {
  for (let i = size - 1; i >= 0; i--) {
    out.push(Math.floor(value / Math.pow(256, i)) & 0xff);
  }
}

export function encodeBinaryPlist(root: PlistValue): Uint8Array {
  interface FlatEntry {
    kind: 'null' | 'bool' | 'int' | 'real' | 'data' | 'string' | 'array' | 'dict';
    value: unknown;
    refs?: number[];
    keyRefs?: number[];
    valRefs?: number[];
  }

  const objects: FlatEntry[] = [];
  const stringPool = new Map<string, number>();

  const register = (val: PlistValue): number => {
    if (val === null || val === undefined) {
      const idx = objects.length;
      objects.push({ kind: 'null', value: null });
      return idx;
    }
    if (typeof val === 'boolean') {
      const idx = objects.length;
      objects.push({ kind: 'bool', value: val });
      return idx;
    }
    if (typeof val === 'number') {
      const idx = objects.length;
      if (Number.isInteger(val) && val >= -0x80000000 && val <= 0xffffffff) {
        objects.push({ kind: 'int', value: val });
      } else {
        objects.push({ kind: 'real', value: val });
      }
      return idx;
    }
    if (typeof val === 'string') {
      const existing = stringPool.get(val);
      if (existing !== undefined) return existing;
      const idx = objects.length;
      objects.push({ kind: 'string', value: val });
      stringPool.set(val, idx);
      return idx;
    }
    if (val instanceof Uint8Array) {
      const idx = objects.length;
      objects.push({ kind: 'data', value: val });
      return idx;
    }
    if (Array.isArray(val)) {
      const idx = objects.length;
      const entry: FlatEntry = { kind: 'array', value: null, refs: [] };
      objects.push(entry);
      entry.refs = val.map((item) => register(item));
      return idx;
    }
    // Plain object dictionary (skip undefined values matching Swift Codable)
    const idx = objects.length;
    const entry: FlatEntry = { kind: 'dict', value: null, keyRefs: [], valRefs: [] };
    objects.push(entry);
    const keys = Object.keys(val).filter((k) => val[k] !== undefined);
    entry.keyRefs = keys.map((k) => register(k));
    entry.valRefs = keys.map((k) => register(val[k]));
    return idx;
  };

  register(root);

  const numObjects = objects.length;
  const objectRefSize = numObjects < 256 ? 1 : numObjects < 65536 ? 2 : 4;

  const chunks: Uint8Array[] = [MAGIC];
  const offsets: number[] = [];
  let cursor = MAGIC.byteLength;

  for (const entry of objects) {
    offsets.push(cursor);
    let chunk: Uint8Array;
    switch (entry.kind) {
      case 'null':
        chunk = new Uint8Array([0x00]);
        break;
      case 'bool':
        chunk = new Uint8Array([entry.value ? 0x09 : 0x08]);
        break;
      case 'int': {
        const n = entry.value as number;
        if (n >= 0 && n <= 0xff) {
          chunk = new Uint8Array([0x10, n]);
        } else if (n >= 0 && n <= 0xffff) {
          chunk = new Uint8Array([0x11, (n >>> 8) & 0xff, n & 0xff]);
        } else if (n >= 0 && n <= 0xffffffff) {
          chunk = new Uint8Array([
            0x12,
            (n >>> 24) & 0xff,
            (n >>> 16) & 0xff,
            (n >>> 8) & 0xff,
            n & 0xff,
          ]);
        } else {
          // 8-byte signed big-endian
          chunk = new Uint8Array(9);
          chunk[0] = 0x13;
          const dv = new DataView(chunk.buffer);
          const hi = Math.floor(n / 0x100000000);
          const lo = n >>> 0;
          dv.setInt32(1, hi, false);
          dv.setUint32(5, lo, false);
        }
        break;
      }
      case 'real': {
        chunk = new Uint8Array(9);
        chunk[0] = 0x23;
        new DataView(chunk.buffer).setFloat64(1, entry.value as number, false);
        break;
      }
      case 'data': {
        const data = entry.value as Uint8Array;
        const header: number[] = [];
        writeLengthHeader(header, 0x40, data.byteLength);
        chunk = new Uint8Array(header.length + data.byteLength);
        chunk.set(header, 0);
        chunk.set(data, header.length);
        break;
      }
      case 'string': {
        const str = entry.value as string;
        const header: number[] = [];
        if (isPureAscii(str)) {
          writeLengthHeader(header, 0x50, str.length);
          chunk = new Uint8Array(header.length + str.length);
          chunk.set(header, 0);
          for (let i = 0; i < str.length; i++) {
            chunk[header.length + i] = str.charCodeAt(i);
          }
        } else {
          writeLengthHeader(header, 0x60, str.length);
          chunk = new Uint8Array(header.length + str.length * 2);
          chunk.set(header, 0);
          const dv = new DataView(chunk.buffer);
          for (let i = 0; i < str.length; i++) {
            dv.setUint16(header.length + i * 2, str.charCodeAt(i), false);
          }
        }
        break;
      }
      case 'array': {
        const refs = entry.refs ?? [];
        const buf: number[] = [];
        writeLengthHeader(buf, 0xa0, refs.length);
        for (const r of refs) pushUIntBE(buf, r, objectRefSize);
        chunk = new Uint8Array(buf);
        break;
      }
      case 'dict': {
        const kRefs = entry.keyRefs ?? [];
        const vRefs = entry.valRefs ?? [];
        const buf: number[] = [];
        writeLengthHeader(buf, 0xd0, kRefs.length);
        for (const r of kRefs) pushUIntBE(buf, r, objectRefSize);
        for (const r of vRefs) pushUIntBE(buf, r, objectRefSize);
        chunk = new Uint8Array(buf);
        break;
      }
    }
    chunks.push(chunk);
    cursor += chunk.byteLength;
  }

  const offsetTableOffset = cursor;
  const offsetIntSize = offsetTableOffset < 256 ? 1 : offsetTableOffset < 65536 ? 2 : 4;
  const offsetTableBytes: number[] = [];
  for (const off of offsets) {
    pushUIntBE(offsetTableBytes, off, offsetIntSize);
  }
  const offsetTable = new Uint8Array(offsetTableBytes);
  chunks.push(offsetTable);
  cursor += offsetTable.byteLength;

  const trailer = new Uint8Array(32);
  const trailerView = new DataView(trailer.buffer);
  trailerView.setUint8(6, offsetIntSize);
  trailerView.setUint8(7, objectRefSize);
  // numObjects (uint64 BE)
  trailerView.setUint32(8, Math.floor(numObjects / 0x100000000), false);
  trailerView.setUint32(12, numObjects >>> 0, false);
  // topObject = 0
  // offsetTableOffset (uint64 BE)
  trailerView.setUint32(24, Math.floor(offsetTableOffset / 0x100000000), false);
  trailerView.setUint32(28, offsetTableOffset >>> 0, false);
  chunks.push(trailer);
  cursor += trailer.byteLength;

  const final = new Uint8Array(cursor);
  let pos = 0;
  for (const c of chunks) {
    final.set(c, pos);
    pos += c.byteLength;
  }
  return final;
}
