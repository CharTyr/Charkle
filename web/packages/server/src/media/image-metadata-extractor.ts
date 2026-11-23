import {
  isAIGenerationEmpty,
  isPhotoExifEmpty,
  type AIGenerationMetadata,
  type PhotoExifMetadata,
} from '@charkle/shared';

/**
 * Pure-TS, 100% Cloudflare Workers-safe image metadata extractor.
 * Extracts camera EXIF/TIFF/GPS/IPTC/ICC/XMP properties and embedded AI generation
 * prompts/parameters (A1111/Forge/Civitai, ComfyUI, NovelAI, InvokeAI, Midjourney,
 * SwarmUI, Draw Things, XMP, and EXIF UserComment).
 *
 * ZERO `node:*` or native (`sharp`) imports. Uses Web-standard `DataView`, `TextDecoder`,
 * and `DecompressionStream('deflate')`.
 */

export interface ExtractedImageMetadata {
  photoExif: PhotoExifMetadata | null;
  aiGeneration: AIGenerationMetadata | null;
}

const MAX_BINARY_SCAN_BYTES = 2 * 1024 * 1024;
const MAX_INFLATE_BYTES = 4 * 1024 * 1024;

const utf8Decoder = new TextDecoder('utf-8', { fatal: false });
const utf8StrictDecoder = new TextDecoder('utf-8', { fatal: true });
const latin1Decoder = new TextDecoder('latin1');

function decodeUtf8OrLatin1(bytes: Uint8Array): string {
  try {
    return utf8StrictDecoder.decode(bytes);
  } catch {
    return latin1Decoder.decode(bytes);
  }
}

function readAscii(bytes: Uint8Array, start: number, len: number): string {
  let out = '';
  const end = Math.min(bytes.byteLength, start + len);
  for (let i = start; i < end; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

function cleanString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '').trim();
  return trimmed.length > 0 ? trimmed : null;
}

function intValue(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (/^-?\d+$/.test(trimmed)) {
      const n = Number.parseInt(trimmed, 10);
      return Number.isSafeInteger(n) ? n : null;
    }
  }
  return null;
}

function doubleValue(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const n = Number.parseFloat(value.trim());
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function int64String(value: unknown): string | null {
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'number' && Number.isFinite(value)) return String(Math.trunc(value));
  return cleanString(value);
}

function decodeHtmlEntities(input: string): string {
  return input
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&#x([0-9a-fA-F]+);/g, (_m, hex: string) => {
      const cp = Number.parseInt(hex, 16);
      return Number.isFinite(cp) ? String.fromCodePoint(cp) : '';
    })
    .replace(/&#(\d+);/g, (_m, dec: string) => {
      const cp = Number.parseInt(dec, 10);
      return Number.isFinite(cp) ? String.fromCodePoint(cp) : '';
    });
}

// MARK: - Formatting Parity

export function formatExposureTime(seconds: number): string | null {
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  if (seconds >= 0.5) {
    if (Math.abs(seconds - Math.round(seconds)) < 0.05) {
      return `${Math.round(seconds)}s`;
    }
    return `${seconds.toFixed(1)}s`;
  }
  const denom = Math.max(1, Math.round(1.0 / seconds));
  return `1/${denom}s`;
}

export function formatExifDate(raw?: string | null, offset?: string | null): string | null {
  const cleaned = cleanString(raw);
  if (!cleaned) return null;
  let normalized = cleaned;
  if (normalized.length >= 10 && normalized[4] === ':' && normalized[7] === ':') {
    normalized = `${normalized.slice(0, 4)}-${normalized.slice(5, 7)}-${normalized.slice(8)}`;
  }
  const cleanOffset = cleanString(offset);
  if (cleanOffset && !normalized.includes(cleanOffset)) {
    return `${normalized} (${cleanOffset})`;
  }
  return normalized;
}

function meteringModeLabel(code: number): string | null {
  switch (code) {
    case 1:
      return '平均测光';
    case 2:
      return '中央重点测光';
    case 3:
      return '点测光';
    case 4:
      return '多点测光';
    case 5:
      return '评价测光';
    case 6:
      return '局部测光';
    default:
      return null;
  }
}

// MARK: - Web-Standard Zlib Inflate (`DecompressionStream`)

async function inflateWithFormat(
  compressed: Uint8Array,
  format: 'deflate' | 'deflate-raw',
): Promise<Uint8Array | null> {
  if (typeof DecompressionStream !== 'function' || compressed.byteLength === 0) return null;
  try {
    const ds = new DecompressionStream(format);
    const writer = ds.writable.getWriter();
    const copy = new Uint8Array(compressed.byteLength);
    copy.set(compressed);
    const writePromise = writer
      .write(copy)
      .then(() => writer.close())
      .catch(() => undefined);

    const reader = ds.readable.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!value) continue;
        total += value.byteLength;
        if (total > MAX_INFLATE_BYTES) {
          await reader.cancel().catch(() => undefined);
          await writePromise;
          return null;
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    await writePromise;
    if (total === 0) return null;
    const out = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) {
      out.set(c, offset);
      offset += c.byteLength;
    }
    return out;
  } catch {
    return null;
  }
}

async function inflateZlib(compressed: Uint8Array): Promise<Uint8Array | null> {
  if (compressed.byteLength < 6) return null;
  const standard = await inflateWithFormat(compressed, 'deflate');
  if (standard) return standard;
  // Fallback for raw deflate streams missing trailer
  return inflateWithFormat(compressed.subarray(2), 'deflate-raw');
}

// MARK: - Internal Parsed Container Bag

interface ParsedTiffBag {
  cameraMake?: string | null;
  cameraModel?: string | null;
  lensModel?: string | null;
  dateTimeOriginal?: string | null;
  dateTimeDigitized?: string | null;
  tiffDateTime?: string | null;
  offsetTimeOriginal?: string | null;
  exposureSeconds?: number | null;
  fNumber?: number | null;
  iso?: number | null;
  focalLengthMM?: number | null;
  focalLength35mm?: number | null;
  exposureBiasEV?: number | null;
  meteringMode?: number | null;
  flash?: number | null;
  whiteBalance?: number | null;
  colorSpace?: number | null;
  dpiWidth?: number | null;
  software?: string | null;
  artist?: string | null;
  copyright?: string | null;
  imageDescription?: string | null;
  userComment?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  altitudeMeters?: number | null;
}

// MARK: - TIFF / EXIF / GPS IFD Reader (Little-Endian `II` & Big-Endian `MM`)

function decodeUtf16Bytes(bytes: Uint8Array, littleEndian: boolean): string {
  const len = bytes.byteLength - (bytes.byteLength % 2);
  let out = '';
  const view = new DataView(bytes.buffer, bytes.byteOffset, len);
  for (let i = 0; i < len; i += 2) {
    const code = view.getUint16(i, littleEndian);
    if (code === 0) continue;
    out += String.fromCharCode(code);
  }
  return out;
}

function cleanExifCommentPrefix(raw: string): string | null {
  let s = raw.replace(/\x00/g, '');
  for (const prefix of ['UNICODE', 'ASCII', 'JIS']) {
    if (s.startsWith(prefix) && s.length > prefix.length) {
      const rest = s.slice(prefix.length).trim();
      if (
        rest.startsWith('{') ||
        rest.includes('Steps:') ||
        rest.includes('Negative prompt:') ||
        rest.includes('Sampler:')
      ) {
        s = rest;
      }
    }
  }
  const trimmed = s.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function decodeExifUserCommentBytes(bytes: Uint8Array, tiffLittleEndian: boolean): string | null {
  if (bytes.byteLength === 0) return null;
  if (bytes.byteLength > 8) {
    const prefix = readAscii(bytes, 0, 8);
    const body = bytes.subarray(8);
    if (prefix.startsWith('UNICODE')) {
      let useLE = tiffLittleEndian;
      let start = 0;
      if (body.byteLength >= 2 && body[0] === 0xff && body[1] === 0xfe) {
        useLE = true;
        start = 2;
      } else if (body.byteLength >= 2 && body[0] === 0xfe && body[1] === 0xff) {
        useLE = false;
        start = 2;
      } else {
        // Heuristic: count zero high bytes in even vs odd slots for ASCII-heavy prompts
        let evenZeros = 0;
        let oddZeros = 0;
        const sampleLen = Math.min(body.byteLength, 128);
        for (let i = 0; i + 1 < sampleLen; i += 2) {
          if (body[i] === 0 && body[i + 1] !== 0) evenZeros++;
          if (body[i] !== 0 && body[i + 1] === 0) oddZeros++;
        }
        if (evenZeros > oddZeros) useLE = false;
        else if (oddZeros > evenZeros) useLE = true;
      }
      const decoded = decodeUtf16Bytes(body.subarray(start), useLE);
      const cleaned = cleanString(decoded);
      if (cleaned) return cleaned;
    } else if (prefix.startsWith('ASCII')) {
      const decoded = decodeUtf8OrLatin1(body);
      const cleaned = cleanString(decoded);
      if (cleaned) return cleaned;
    }
  }
  return cleanExifCommentPrefix(decodeUtf8OrLatin1(bytes));
}

function parseTiffExif(tiffBytes: Uint8Array): ParsedTiffBag | null {
  if (tiffBytes.byteLength < 8) return null;
  const b0 = tiffBytes[0];
  const b1 = tiffBytes[1];
  let le: boolean;
  if (b0 === 0x49 && b1 === 0x49) {
    le = true; // II
  } else if (b0 === 0x4d && b1 === 0x4d) {
    le = false; // MM
  } else {
    return null;
  }

  const view = new DataView(tiffBytes.buffer, tiffBytes.byteOffset, tiffBytes.byteLength);
  if (view.getUint16(2, le) !== 42) return null;

  const bag: ParsedTiffBag = {};
  const visitedIFDs = new Set<number>();

  const TYPE_SIZES: Record<number, number> = {
    1: 1, // BYTE
    2: 1, // ASCII
    3: 2, // SHORT
    4: 4, // LONG
    5: 8, // RATIONAL
    6: 1, // SBYTE
    7: 1, // UNDEFINED
    8: 2, // SSHORT
    9: 4, // SLONG
    10: 8, // SRATIONAL
    11: 4, // FLOAT
    12: 8, // DOUBLE
  };

  interface IFDEntry {
    tag: number;
    type: number;
    count: number;
    valueOffset: number;
    totalBytes: number;
  }

  const readIFD = (offset: number): IFDEntry[] => {
    if (offset < 8 || offset + 2 > tiffBytes.byteLength || visitedIFDs.has(offset)) return [];
    visitedIFDs.add(offset);
    const numEntries = view.getUint16(offset, le);
    const maxEntries = Math.min(numEntries, 256);
    const entries: IFDEntry[] = [];
    for (let i = 0; i < maxEntries; i++) {
      const entryOffset = offset + 2 + i * 12;
      if (entryOffset + 12 > tiffBytes.byteLength) break;
      const tag = view.getUint16(entryOffset, le);
      const type = view.getUint16(entryOffset + 2, le);
      const count = view.getUint32(entryOffset + 4, le);
      const unitSize = TYPE_SIZES[type] ?? 0;
      if (unitSize === 0 || count > 2_000_000) continue;
      const totalBytes = count * unitSize;
      const valueOffset = totalBytes <= 4 ? entryOffset + 8 : view.getUint32(entryOffset + 8, le);
      if (valueOffset < 0 || valueOffset + totalBytes > tiffBytes.byteLength) continue;
      entries.push({ tag, type, count, valueOffset, totalBytes });
    }
    return entries;
  };

  const readEntryBytes = (e: IFDEntry): Uint8Array =>
    tiffBytes.subarray(e.valueOffset, e.valueOffset + e.totalBytes);

  const readEntryString = (e: IFDEntry): string | null => {
    const raw = readEntryBytes(e);
    let end = raw.byteLength;
    while (end > 0 && raw[end - 1] === 0) end--;
    return cleanString(decodeUtf8OrLatin1(raw.subarray(0, end)));
  };

  const readEntryUint = (e: IFDEntry): number | null => {
    if (e.count < 1) return null;
    if (e.type === 3) return view.getUint16(e.valueOffset, le);
    if (e.type === 4) return view.getUint32(e.valueOffset, le);
    if (e.type === 1) return tiffBytes[e.valueOffset];
    if (e.type === 8) return view.getInt16(e.valueOffset, le);
    if (e.type === 9) return view.getInt32(e.valueOffset, le);
    return null;
  };

  const readEntryRational = (e: IFDEntry, index = 0): number | null => {
    if (index >= e.count) return null;
    const pos = e.valueOffset + index * 8;
    if (pos + 8 > tiffBytes.byteLength) return null;
    if (e.type === 5) {
      const num = view.getUint32(pos, le);
      const den = view.getUint32(pos + 4, le);
      return den === 0 ? null : num / den;
    }
    if (e.type === 10) {
      const num = view.getInt32(pos, le);
      const den = view.getInt32(pos + 4, le);
      return den === 0 ? null : num / den;
    }
    if (e.type === 11 && e.valueOffset + index * 4 + 4 <= tiffBytes.byteLength) {
      return view.getFloat32(e.valueOffset + index * 4, le);
    }
    if (e.type === 12 && pos + 8 <= tiffBytes.byteLength) {
      return view.getFloat64(pos, le);
    }
    return readEntryUint(e);
  };

  const ifd0Offset = view.getUint32(4, le);
  const ifd0 = readIFD(ifd0Offset);
  let exifPointer: number | null = null;
  let gpsPointer: number | null = null;
  let xResolution: number | null = null;
  let resolutionUnit = 2; // default inches

  for (const e of ifd0) {
    switch (e.tag) {
      case 0x010e:
        bag.imageDescription = readEntryString(e);
        break;
      case 0x010f:
        bag.cameraMake = readEntryString(e);
        break;
      case 0x0110:
        bag.cameraModel = readEntryString(e);
        break;
      case 0x011a:
        xResolution = readEntryRational(e);
        break;
      case 0x0128: {
        const u = readEntryUint(e);
        if (u != null) resolutionUnit = u;
        break;
      }
      case 0x0131:
        bag.software = readEntryString(e);
        break;
      case 0x0132:
        bag.tiffDateTime = readEntryString(e);
        break;
      case 0x013b:
        bag.artist = readEntryString(e);
        break;
      case 0x8298:
        bag.copyright = readEntryString(e);
        break;
      case 0x8769:
        exifPointer = readEntryUint(e);
        break;
      case 0x8825:
        gpsPointer = readEntryUint(e);
        break;
    }
  }

  if (xResolution != null && xResolution > 0) {
    if (resolutionUnit === 3) {
      bag.dpiWidth = Math.round(xResolution * 2.54);
    } else if (resolutionUnit === 2) {
      bag.dpiWidth = Math.round(xResolution);
    }
  }

  if (exifPointer != null) {
    const exifEntries = readIFD(exifPointer);
    for (const e of exifEntries) {
      switch (e.tag) {
        case 0x829a:
          bag.exposureSeconds = readEntryRational(e);
          break;
        case 0x829d:
          bag.fNumber = readEntryRational(e);
          break;
        case 0x8827:
          bag.iso = readEntryUint(e);
          break;
        case 0x9003:
          bag.dateTimeOriginal = readEntryString(e);
          break;
        case 0x9004:
          bag.dateTimeDigitized = readEntryString(e);
          break;
        case 0x9011:
          bag.offsetTimeOriginal = readEntryString(e);
          break;
        case 0x9204:
          bag.exposureBiasEV = readEntryRational(e);
          break;
        case 0x9207:
          bag.meteringMode = readEntryUint(e);
          break;
        case 0x9209:
          bag.flash = readEntryUint(e);
          break;
        case 0x920a:
          bag.focalLengthMM = readEntryRational(e);
          break;
        case 0x9286:
          bag.userComment = decodeExifUserCommentBytes(readEntryBytes(e), le);
          break;
        case 0xa001:
          bag.colorSpace = readEntryUint(e);
          break;
        case 0xa403:
          bag.whiteBalance = readEntryUint(e);
          break;
        case 0xa405:
          bag.focalLength35mm = readEntryUint(e);
          break;
        case 0xa434:
          bag.lensModel = readEntryString(e);
          break;
      }
    }
  }

  if (gpsPointer != null) {
    const gpsEntries = readIFD(gpsPointer);
    let latRef: string | null = null;
    let lonRef: string | null = null;
    let altRef: number | null = null;
    let latVal: number | null = null;
    let lonVal: number | null = null;
    let altVal: number | null = null;

    const readDMS = (e: IFDEntry): number | null => {
      if (e.count < 3) return null;
      const d = readEntryRational(e, 0);
      const m = readEntryRational(e, 1);
      const s = readEntryRational(e, 2);
      if (d == null || m == null || s == null) return null;
      return d + m / 60 + s / 3600;
    };

    for (const e of gpsEntries) {
      switch (e.tag) {
        case 0x0001:
          latRef = readEntryString(e);
          break;
        case 0x0002:
          latVal = readDMS(e);
          break;
        case 0x0003:
          lonRef = readEntryString(e);
          break;
        case 0x0004:
          lonVal = readDMS(e);
          break;
        case 0x0005:
          altRef = readEntryUint(e);
          break;
        case 0x0006:
          altVal = readEntryRational(e);
          break;
      }
    }

    if (latVal != null && Number.isFinite(latVal)) {
      bag.latitude = latRef?.toUpperCase() === 'S' ? -Math.abs(latVal) : Math.abs(latVal);
    }
    if (lonVal != null && Number.isFinite(lonVal)) {
      bag.longitude = lonRef?.toUpperCase() === 'W' ? -Math.abs(lonVal) : Math.abs(lonVal);
    }
    if (altVal != null && Number.isFinite(altVal)) {
      bag.altitudeMeters = altRef === 1 ? -Math.abs(altVal) : Math.abs(altVal);
    }
  }

  return bag;
}

// MARK: - ICC Profile Name Parser

function extractIccProfileName(iccBytes: Uint8Array): string | null {
  if (iccBytes.byteLength < 132) return null;
  const view = new DataView(iccBytes.buffer, iccBytes.byteOffset, iccBytes.byteLength);
  const tagCount = Math.min(view.getUint32(128, false), 128);
  for (let i = 0; i < tagCount; i++) {
    const pos = 132 + i * 12;
    if (pos + 12 > iccBytes.byteLength) break;
    const sig = readAscii(iccBytes, pos, 4);
    if (sig !== 'desc') continue;
    const offset = view.getUint32(pos + 4, false);
    const size = view.getUint32(pos + 8, false);
    if (offset + 12 > iccBytes.byteLength || size < 12) continue;
    const typeSig = readAscii(iccBytes, offset, 4);
    if (typeSig === 'desc') {
      const asciiLen = view.getUint32(offset + 8, false);
      if (asciiLen > 0 && offset + 12 + asciiLen <= iccBytes.byteLength) {
        const raw = iccBytes.subarray(offset + 12, offset + 12 + asciiLen);
        let end = raw.byteLength;
        while (end > 0 && raw[end - 1] === 0) end--;
        return cleanString(decodeUtf8OrLatin1(raw.subarray(0, end)));
      }
    } else if (typeSig === 'mluc' && offset + 28 <= iccBytes.byteLength) {
      const recCount = view.getUint32(offset + 8, false);
      if (recCount > 0) {
        const strLen = view.getUint32(offset + 20, false);
        const strOff = view.getUint32(offset + 24, false);
        if (offset + strOff + strLen <= iccBytes.byteLength) {
          return cleanString(
            decodeUtf16Bytes(iccBytes.subarray(offset + strOff, offset + strOff + strLen), false),
          );
        }
      }
    }
  }
  return null;
}

// MARK: - IPTC Parser (Photoshop APP13 8BIM / 0x0404)

interface IptcBag {
  byline?: string | null;
  copyright?: string | null;
  caption?: string | null;
}

function parsePhotoshopIptc(payload: Uint8Array): IptcBag {
  const out: IptcBag = {};
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  let pos = 0;
  // Skip "Photoshop 3.0\0"
  if (payload.byteLength >= 14 && readAscii(payload, 0, 13) === 'Photoshop 3.0') {
    pos = 14;
  }
  while (pos + 12 <= payload.byteLength) {
    if (readAscii(payload, pos, 4) !== '8BIM') break;
    const resourceId = view.getUint16(pos + 4, false);
    const nameLen = payload[pos + 6];
    const namePadded = nameLen + 1 + ((nameLen + 1) % 2);
    const sizePos = pos + 6 + namePadded;
    if (sizePos + 4 > payload.byteLength) break;
    const dataSize = view.getUint32(sizePos, false);
    const dataStart = sizePos + 4;
    if (dataStart + dataSize > payload.byteLength) break;

    if (resourceId === 0x0404) {
      // IPTC-NAA record stream
      let p = dataStart;
      const end = dataStart + dataSize;
      while (p + 5 <= end) {
        if (payload[p] !== 0x1c) {
          p++;
          continue;
        }
        const record = payload[p + 1];
        const dataset = payload[p + 2];
        const len = view.getUint16(p + 3, false);
        p += 5;
        if (p + len > end) break;
        if (record === 2) {
          const val = cleanString(decodeUtf8OrLatin1(payload.subarray(p, p + len)));
          if (val) {
            if (dataset === 80 && !out.byline) out.byline = val;
            else if (dataset === 116 && !out.copyright) out.copyright = val;
            else if (dataset === 120 && !out.caption) out.caption = val;
          }
        }
        p += len;
      }
    }

    pos = dataStart + dataSize + (dataSize % 2);
  }
  return out;
}

// MARK: - XMP Tag Extraction

function extractXmlTagContent(xml: string, tagName: string): string | null {
  const escaped = tagName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const elemRe = new RegExp(`<${escaped}\\b[^>]*>([\\s\\S]*?)<\\/${escaped}>`, 'i');
  const m = elemRe.exec(xml);
  if (m) {
    const inner = m[1].replace(/<\/?rdf:[^>]+>/gi, '');
    const decoded = decodeHtmlEntities(inner).trim();
    if (decoded.length > 0) return decoded;
  }
  const attrRe = new RegExp(`\\b${escaped}\\s*=\\s*"([^"]+)"`, 'i');
  const am = attrRe.exec(xml);
  if (am) {
    const decoded = decodeHtmlEntities(am[1]).trim();
    if (decoded.length > 0) return decoded;
  }
  return null;
}

function parseXmpEntries(xml: string): Record<string, string> {
  const out: Record<string, string> = {};
  const keys = [
    'exif:UserComment',
    'dc:description',
    'aux:Lens',
    'exifEX:LensModel',
    'xmp:CreatorTool',
    'dc:creator',
    'dc:rights',
  ];
  for (const key of keys) {
    const val = extractXmlTagContent(xml, key);
    if (val) out[key] = val;
  }
  return out;
}

// MARK: - PNG Binary Chunk Scanner (`tEXt`, `iTXt`, `zTXt`, `eXIf`, `pHYs`, `iCCP`, `IHDR`)

function isPng(bytes: Uint8Array): boolean {
  return (
    bytes.byteLength > 16 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  );
}

interface ParsedPngContainer {
  textChunks: Record<string, string>;
  tiffBag: ParsedTiffBag | null;
  bitDepth: number | null;
  dpiWidth: number | null;
  colorProfile: string | null;
}

async function parsePngContainer(bytes: Uint8Array): Promise<ParsedPngContainer> {
  const textChunks: Record<string, string> = {};
  let tiffBag: ParsedTiffBag | null = null;
  let bitDepth: number | null = null;
  let dpiWidth: number | null = null;
  let colorProfile: string | null = null;

  if (!isPng(bytes)) {
    return { textChunks, tiffBag, bitDepth, dpiWidth, colorProfile };
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 8;
  const total = bytes.byteLength;

  while (offset + 12 <= total) {
    const length = view.getUint32(offset, false);
    const dataStart = offset + 8;
    if (length < 0 || dataStart + length + 4 > total) break;

    const chunkType = readAscii(bytes, offset + 4, 4);
    if (chunkType === 'IEND') break;

    if (length > 0 && length <= 1_500_000) {
      const payload = bytes.subarray(dataStart, dataStart + length);
      switch (chunkType) {
        case 'IHDR':
          if (payload.byteLength >= 9) {
            bitDepth = payload[8];
          }
          break;
        case 'pHYs':
          if (payload.byteLength >= 9 && payload[8] === 1) {
            const pv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
            const ppuX = pv.getUint32(0, false);
            if (ppuX > 0) dpiWidth = Math.round(ppuX * 0.0254);
          }
          break;
        case 'iCCP': {
          const nul = payload.indexOf(0);
          if (nul > 0) {
            const name = cleanString(latin1Decoder.decode(payload.subarray(0, nul)));
            if (name) colorProfile = name;
          }
          break;
        }
        case 'sRGB':
          if (!colorProfile) colorProfile = 'sRGB';
          break;
        case 'eXIf':
          tiffBag = parseTiffExif(payload);
          break;
        case 'tEXt': {
          const nul = payload.indexOf(0);
          if (nul > 0) {
            const key = latin1Decoder.decode(payload.subarray(0, nul));
            const val = decodeUtf8OrLatin1(payload.subarray(nul + 1));
            if (key) textChunks[key] = val;
          }
          break;
        }
        case 'zTXt': {
          const nul = payload.indexOf(0);
          if (nul > 0 && nul + 2 < payload.byteLength && payload[nul + 1] === 0) {
            const key = latin1Decoder.decode(payload.subarray(0, nul));
            const inflated = await inflateZlib(payload.subarray(nul + 2));
            if (key && inflated) {
              textChunks[key] = decodeUtf8OrLatin1(inflated);
            }
          }
          break;
        }
        case 'iTXt': {
          const nul1 = payload.indexOf(0);
          if (nul1 > 0 && nul1 + 3 < payload.byteLength) {
            const key = latin1Decoder.decode(payload.subarray(0, nul1));
            const isCompressed = payload[nul1 + 1] === 1;
            const method = payload[nul1 + 2];
            const nul2 = payload.indexOf(0, nul1 + 3);
            if (nul2 >= 0 && nul2 + 1 < payload.byteLength) {
              const nul3 = payload.indexOf(0, nul2 + 1);
              if (nul3 >= 0 && nul3 + 1 <= payload.byteLength) {
                const rawText = payload.subarray(nul3 + 1);
                let finalBytes: Uint8Array | null = rawText;
                if (isCompressed) {
                  finalBytes = method === 0 ? await inflateZlib(rawText) : null;
                }
                if (key && finalBytes) {
                  textChunks[key] = decodeUtf8OrLatin1(finalBytes);
                }
              }
            }
          }
          break;
        }
      }
    }

    offset = dataStart + length + 4;
  }

  return { textChunks, tiffBag, bitDepth, dpiWidth, colorProfile };
}

export async function extractPNGTextChunks(bytes: Uint8Array): Promise<Record<string, string>> {
  const capped = bytes.byteLength > MAX_BINARY_SCAN_BYTES
    ? bytes.subarray(0, MAX_BINARY_SCAN_BYTES)
    : bytes;
  const parsed = await parsePngContainer(capped);
  return parsed.textChunks;
}

// MARK: - JPEG & WebP Binary Container Parsers

interface ParsedBinaryMetadata {
  tiffBag: ParsedTiffBag | null;
  xmpStrings: string[];
  iptc: IptcBag;
  pngChunks: Record<string, string>;
  colorProfile: string | null;
  bitDepth: number | null;
  dpiWidth: number | null;
}

function parseJpegContainer(bytes: Uint8Array): ParsedBinaryMetadata {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let tiffBag: ParsedTiffBag | null = null;
  const xmpStrings: string[] = [];
  let iptc: IptcBag = {};
  let colorProfile: string | null = null;
  let bitDepth: number | null = null;
  let dpiWidth: number | null = null;
  const iccParts = new Map<number, Uint8Array>();
  let iccTotal = 0;

  let offset = 2;
  while (offset + 4 <= bytes.byteLength) {
    if (bytes[offset] !== 0xff) {
      offset++;
      continue;
    }
    while (offset < bytes.byteLength && bytes[offset] === 0xff) offset++;
    if (offset >= bytes.byteLength) break;
    const marker = bytes[offset++];
    if (marker === 0xd9 || marker === 0xda) break; // EOI or SOS
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.byteLength) break;
    const segLen = view.getUint16(offset, false);
    if (segLen < 2) break;
    const payloadStart = offset + 2;
    const payloadEnd = Math.min(bytes.byteLength, offset + segLen);
    const payload = bytes.subarray(payloadStart, payloadEnd);

    if (
      (marker >= 0xc0 && marker <= 0xc3) ||
      (marker >= 0xc5 && marker <= 0xc7) ||
      (marker >= 0xc9 && marker <= 0xcb) ||
      (marker >= 0xcd && marker <= 0xcf)
    ) {
      if (payload.byteLength >= 1 && bitDepth == null) {
        bitDepth = payload[0];
      }
    } else if (marker === 0xe0 && payload.byteLength >= 12) {
      // JFIF
      if (readAscii(payload, 0, 5) === 'JFIF\0') {
        const pv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        const units = payload[7];
        const xDens = pv.getUint16(8, false);
        if (xDens > 0 && dpiWidth == null) {
          if (units === 1) dpiWidth = xDens;
          else if (units === 2) dpiWidth = Math.round(xDens * 2.54);
        }
      }
    } else if (marker === 0xe1) {
      // APP1: EXIF or XMP
      if (payload.byteLength > 14 && readAscii(payload, 0, 6) === 'Exif\0\0') {
        const parsed = parseTiffExif(payload.subarray(6));
        if (parsed && !tiffBag) tiffBag = parsed;
      } else if (
        payload.byteLength > 29 &&
        readAscii(payload, 0, 29) === 'http://ns.adobe.com/xap/1.0/\0'
      ) {
        const xmp = utf8Decoder.decode(payload.subarray(29)).trim();
        if (xmp) xmpStrings.push(xmp);
      }
    } else if (marker === 0xe2 && payload.byteLength > 14) {
      // APP2: ICC_PROFILE
      if (readAscii(payload, 0, 12) === 'ICC_PROFILE\0') {
        const seqNo = payload[12];
        const totalCnt = payload[13];
        if (seqNo >= 1 && totalCnt >= 1 && totalCnt <= 32) {
          iccTotal = totalCnt;
          iccParts.set(seqNo, payload.subarray(14));
        }
      }
    } else if (marker === 0xed && payload.byteLength > 16) {
      // APP13: IPTC
      const parsedIptc = parsePhotoshopIptc(payload);
      iptc = {
        byline: iptc.byline ?? parsedIptc.byline,
        copyright: iptc.copyright ?? parsedIptc.copyright,
        caption: iptc.caption ?? parsedIptc.caption,
      };
    }

    offset += segLen;
  }

  if (iccTotal > 0 && iccParts.size > 0) {
    let totalLen = 0;
    const ordered: Uint8Array[] = [];
    for (let i = 1; i <= iccTotal; i++) {
      const part = iccParts.get(i);
      if (!part) break;
      ordered.push(part);
      totalLen += part.byteLength;
    }
    if (totalLen >= 132) {
      const combined = new Uint8Array(totalLen);
      let pos = 0;
      for (const p of ordered) {
        combined.set(p, pos);
        pos += p.byteLength;
      }
      colorProfile = extractIccProfileName(combined);
    }
  }

  return {
    tiffBag,
    xmpStrings,
    iptc,
    pngChunks: {},
    colorProfile,
    bitDepth,
    dpiWidth,
  };
}

function parseWebPContainer(bytes: Uint8Array): ParsedBinaryMetadata {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let tiffBag: ParsedTiffBag | null = null;
  const xmpStrings: string[] = [];
  let colorProfile: string | null = null;

  let offset = 12;
  while (offset + 8 <= bytes.byteLength) {
    const fourCC = readAscii(bytes, offset, 4);
    const size = view.getUint32(offset + 4, true);
    const dataStart = offset + 8;
    if (dataStart + size > bytes.byteLength) break;
    const payload = bytes.subarray(dataStart, dataStart + size);

    if (fourCC === 'EXIF' && !tiffBag) {
      const tiffSlice =
        payload.byteLength > 6 && readAscii(payload, 0, 6) === 'Exif\0\0'
          ? payload.subarray(6)
          : payload;
      tiffBag = parseTiffExif(tiffSlice);
    } else if (fourCC === 'XMP ') {
      const xmp = utf8Decoder.decode(payload).trim();
      if (xmp) xmpStrings.push(xmp);
    } else if (fourCC === 'ICCP' && !colorProfile) {
      colorProfile = extractIccProfileName(payload);
    }

    offset = dataStart + size + (size % 2);
  }

  return {
    tiffBag,
    xmpStrings,
    iptc: {},
    pngChunks: {},
    colorProfile,
    bitDepth: null,
    dpiWidth: null,
  };
}

// MARK: - AI Generation Parsers (Priority A -> G matching ImageMetadataExtractor.swift)

function parseCommaSeparatedKeyValues(raw: string): Record<string, string> {
  if (!raw) return {};
  const pairs: Record<string, string> = {};
  const parts: string[] = [];
  let current = '';
  let inQuotes = false;
  let braceDepth = 0;

  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (ch === '"') {
      inQuotes = !inQuotes;
      current += ch;
    } else if (!inQuotes && (ch === '{' || ch === '[')) {
      braceDepth++;
      current += ch;
    } else if (!inQuotes && (ch === '}' || ch === ']')) {
      braceDepth = Math.max(0, braceDepth - 1);
      current += ch;
    } else if (ch === ',' && !inQuotes && braceDepth === 0) {
      parts.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  if (current) parts.push(current);

  for (const part of parts) {
    const colon = part.indexOf(':');
    if (colon < 0) continue;
    const key = part.slice(0, colon).trim();
    let val = part.slice(colon + 1).trim();
    if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
      val = val.slice(1, -1);
    }
    if (key && val) {
      pairs[key] = val;
    }
  }
  return pairs;
}

function extractLoraTags(prompt: string): string[] {
  const re = /<lora:([^:>]+)(?::([^>]+))?>/g;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(prompt)) !== null) {
    const name = m[1].trim();
    const label = m[2] ? `${name}:${m[2]}` : name;
    if (name && !out.includes(label)) {
      out.push(label);
    }
  }
  return out;
}

function deduplicatedLines(items: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of items) {
    const trimmed = item.trim();
    if (trimmed && !seen.has(trimmed)) {
      seen.add(trimmed);
      out.push(trimmed);
    }
  }
  return out;
}

function lastPathComponent(raw: string): string {
  const normalized = raw.replace(/\\/g, '/');
  const idx = normalized.lastIndexOf('/');
  return idx >= 0 ? normalized.slice(idx + 1) : normalized;
}

/**
 * Parses A1111 / Forge / reForge / Civitai `parameters` text block.
 */
export function parseA1111Parameters(raw: string): AIGenerationMetadata | null {
  const normalized = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
  if (!normalized) return null;

  const lines = normalized.split('\n');
  let paramLineIndex: number | null = null;
  for (let idx = lines.length - 1; idx >= 0; idx--) {
    const line = lines[idx].trim();
    if (line.startsWith('Steps:') || (line.includes('Sampler:') && line.includes('Seed:'))) {
      paramLineIndex = idx;
      break;
    }
  }

  const headerLines = paramLineIndex != null ? lines.slice(0, paramLineIndex) : lines;
  const paramLine = paramLineIndex != null ? lines.slice(paramLineIndex).join(', ') : '';
  const headerText = headerLines.join('\n');

  let positivePrompt: string;
  let negativePrompt: string | null = null;
  const negMatch = /Negative prompt:/i.exec(headerText);
  if (negMatch) {
    positivePrompt = headerText.slice(0, negMatch.index).trim();
    const neg = headerText.slice(negMatch.index + negMatch[0].length).trim();
    negativePrompt = neg.length > 0 ? neg : null;
  } else {
    positivePrompt = headerText.trim();
  }

  const kv = parseCommaSeparatedKeyValues(paramLine);
  const steps = intValue(kv['Steps']);
  const sampler = kv['Sampler'] ?? null;
  const scheduler = kv['Schedule type'] ?? kv['Scheduler'] ?? null;
  const cfgScale = doubleValue(kv['CFG scale'] ?? kv['Distilled CFG Scale']);
  const seed = kv['Seed'] ?? null;
  const sizeText = kv['Size'] ? kv['Size'].replace(/x/g, ' × ') : null;
  const modelName = kv['Model'] ?? null;
  const modelHash = kv['Model hash'] ?? null;
  const clipSkip = intValue(kv['Clip skip']);

  const loras = extractLoraTags(positivePrompt);
  if (kv['Lora hashes']) {
    for (const pair of kv['Lora hashes'].split(',')) {
      const name = pair.split(':')[0]?.replace(/["\s]+/g, ' ').trim() ?? '';
      if (name && !loras.includes(name)) {
        loras.push(name);
      }
    }
  }

  const knownKeys = new Set([
    'Steps',
    'Sampler',
    'Schedule type',
    'Scheduler',
    'CFG scale',
    'Seed',
    'Size',
    'Model',
    'Model hash',
    'Clip skip',
    'Lora hashes',
  ]);
  const extraParameters: Record<string, string> = {};
  for (const [k, v] of Object.entries(kv)) {
    if (!knownKeys.has(k) && Object.keys(extraParameters).length < 8) {
      extraParameters[k] = v;
    }
  }

  let generator = 'Stable Diffusion (A1111)';
  const version = kv['Version'];
  if (version) {
    const lv = version.toLowerCase();
    if (lv.includes('forge')) generator = 'SD WebUI Forge';
    else if (lv.includes('comfy')) generator = 'ComfyUI';
    else generator = `Stable Diffusion (${version})`;
  }

  const meta: AIGenerationMetadata = {
    generator,
    prompt: positivePrompt || null,
    negativePrompt,
    modelName,
    modelHash,
    sampler,
    scheduler,
    steps,
    cfgScale,
    seed,
    sizeText,
    clipSkip,
    loras,
    extraParameters,
    rawParameters: normalized.slice(0, 8000),
  };
  return isAIGenerationEmpty(meta) ? null : meta;
}

/**
 * Parses ComfyUI node-graph JSON (`prompt` chunk) by tracing sampler, conditioning,
 * checkpoint, LoRA, and latent nodes.
 */
export function parseComfyUIPromptJSON(rawJSON: string): AIGenerationMetadata | null {
  let root: unknown;
  try {
    root = JSON.parse(rawJSON);
  } catch {
    return null;
  }
  if (!root || typeof root !== 'object' || Array.isArray(root)) return null;

  const nodes = new Map<string, { classType: string; inputs: Record<string, unknown> }>();
  for (const [nodeID, rawVal] of Object.entries(root as Record<string, unknown>)) {
    if (!rawVal || typeof rawVal !== 'object' || Array.isArray(rawVal)) continue;
    const dict = rawVal as Record<string, unknown>;
    if (typeof dict.class_type !== 'string') continue;
    const inputs =
      dict.inputs && typeof dict.inputs === 'object' && !Array.isArray(dict.inputs)
        ? (dict.inputs as Record<string, unknown>)
        : {};
    nodes.set(nodeID, { classType: dict.class_type, inputs });
  }
  if (nodes.size === 0) return null;

  const linkedNodeID = (value: unknown): string | null => {
    if (!Array.isArray(value) || value.length === 0) return null;
    if (typeof value[0] === 'string') return value[0];
    if (typeof value[0] === 'number' && Number.isFinite(value[0])) return String(Math.trunc(value[0]));
    return null;
  };

  const collectPrompts = (startID: string | null, visited: Set<string>): string[] => {
    if (!startID || visited.has(startID)) return [];
    const node = nodes.get(startID);
    if (!node) return [];
    visited.add(startID);

    const { inputs } = node;
    const lowerType = node.classType.toLowerCase();
    const found: string[] = [];

    for (const key of ['text', 'clip_l', 't5xxl', 'text_g', 'text_l', 'prompt', 'positive', 'string', 'value']) {
      const val = inputs[key];
      if (typeof val === 'string') {
        const trimmed = val.trim();
        if (trimmed && !found.includes(trimmed)) {
          found.push(trimmed);
        }
      } else {
        const linked = linkedNodeID(val);
        if (linked) {
          found.push(...collectPrompts(linked, visited));
        }
      }
    }

    if (found.length === 0 || lowerType.includes('combine') || lowerType.includes('concat')) {
      for (const key of [
        'conditioning',
        'conditioning_1',
        'conditioning_2',
        'conditioning_to',
        'conditioning_from',
        'positive',
        'guider',
      ]) {
        const linked = linkedNodeID(inputs[key]);
        if (linked) {
          found.push(...collectPrompts(linked, visited));
        }
      }
    }
    return found;
  };

  const positiveTexts: string[] = [];
  const negativeTexts: string[] = [];
  let steps: number | null = null;
  let cfg: number | null = null;
  let sampler: string | null = null;
  let scheduler: string | null = null;
  let seed: string | null = null;
  let modelName: string | null = null;
  let sizeText: string | null = null;
  const loras: string[] = [];

  for (const node of nodes.values()) {
    const lower = node.classType.toLowerCase();
    const { inputs } = node;

    if (lower.includes('ksampler') || lower.includes('samplercustom') || lower.includes('sampler')) {
      if (steps == null) steps = intValue(inputs.steps);
      if (cfg == null) cfg = doubleValue(inputs.cfg);
      if (sampler == null) sampler = cleanString(inputs.sampler_name);
      if (scheduler == null) scheduler = cleanString(inputs.scheduler);
      if (seed == null) seed = int64String(inputs.seed ?? inputs.noise_seed);

      const posID = linkedNodeID(inputs.positive);
      const guiderID = linkedNodeID(inputs.guider);
      if (posID) {
        positiveTexts.push(...collectPrompts(posID, new Set()));
      } else if (guiderID) {
        positiveTexts.push(...collectPrompts(guiderID, new Set()));
      }

      const negID = linkedNodeID(inputs.negative);
      if (negID) {
        negativeTexts.push(...collectPrompts(negID, new Set()));
      }
    }

    if (lower.includes('randomnoise') && seed == null) {
      seed = int64String(inputs.noise_seed);
    }
    if (lower.includes('basicscheduler')) {
      if (steps == null) steps = intValue(inputs.steps);
      if (scheduler == null) scheduler = cleanString(inputs.scheduler);
    }
    if (lower.includes('ksamplerselect') && sampler == null) {
      sampler = cleanString(inputs.sampler_name);
    }
    if (lower.includes('fluxguidance') && cfg == null) {
      cfg = doubleValue(inputs.guidance);
    }

    if (
      (lower.includes('checkpointloader') || lower.includes('unetloader') || lower.includes('diffusionmodel')) &&
      modelName == null
    ) {
      const ckpt =
        cleanString(inputs.ckpt_name) ??
        cleanString(inputs.unet_name) ??
        cleanString(inputs.model_name);
      if (ckpt) modelName = lastPathComponent(ckpt);
    }
    if (lower.includes('lora')) {
      const lora = cleanString(inputs.lora_name);
      if (lora) {
        const clean = lastPathComponent(lora);
        if (!loras.includes(clean)) loras.push(clean);
      }
    }
    if (lower.includes('latentimage') && sizeText == null) {
      const w = intValue(inputs.width);
      const h = intValue(inputs.height);
      if (w != null && h != null && w > 0 && h > 0) {
        sizeText = `${w} × ${h}`;
      }
    }
  }

  if (positiveTexts.length === 0) {
    const sortedIDs = Array.from(nodes.keys()).sort((a, b) => (Number(a) || 0) - (Number(b) || 0));
    const candidates: string[] = [];
    for (const id of sortedIDs) {
      const node = nodes.get(id);
      if (!node || !node.classType.toLowerCase().includes('cliptextencode')) continue;
      const txt =
        cleanString(node.inputs.text) ??
        cleanString(node.inputs.t5xxl) ??
        cleanString(node.inputs.clip_l);
      if (txt && !candidates.includes(txt)) {
        candidates.push(txt);
      }
    }
    if (candidates[0]) positiveTexts.push(candidates[0]);
    if (candidates.length >= 2 && negativeTexts.length === 0) negativeTexts.push(candidates[1]);
  }

  const posJoined = deduplicatedLines(positiveTexts).join('\n');
  const negJoined = deduplicatedLines(negativeTexts).join('\n');

  const meta: AIGenerationMetadata = {
    generator: 'ComfyUI',
    prompt: posJoined || null,
    negativePrompt: negJoined || null,
    modelName,
    modelHash: null,
    sampler,
    scheduler,
    steps,
    cfgScale: cfg,
    seed,
    sizeText,
    clipSkip: null,
    loras,
    extraParameters: {},
    rawParameters: rawJSON.slice(0, 8000),
  };
  return isAIGenerationEmpty(meta) ? null : meta;
}

function parseNovelAIMetadata(
  commentJSON: string,
  description?: string | null,
): AIGenerationMetadata | null {
  let dict: Record<string, unknown>;
  try {
    const parsed = JSON.parse(commentJSON) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    dict = parsed as Record<string, unknown>;
  } catch {
    return null;
  }

  let prompt = cleanString(dict.prompt) ?? cleanString(description);
  if (!prompt && dict.v4_prompt && typeof dict.v4_prompt === 'object') {
    const caption = (dict.v4_prompt as Record<string, unknown>).caption as
      | Record<string, unknown>
      | undefined;
    prompt = cleanString(caption?.base_caption);
  }
  let negative = cleanString(dict.uc);
  if (!negative && dict.v4_negative_prompt && typeof dict.v4_negative_prompt === 'object') {
    const caption = (dict.v4_negative_prompt as Record<string, unknown>).caption as
      | Record<string, unknown>
      | undefined;
    negative = cleanString(caption?.base_caption);
  }

  const w = intValue(dict.width);
  const h = intValue(dict.height);
  const meta: AIGenerationMetadata = {
    generator: 'NovelAI',
    prompt,
    negativePrompt: negative,
    modelName: null,
    modelHash: null,
    sampler: cleanString(dict.sampler),
    scheduler: null,
    steps: intValue(dict.steps),
    cfgScale: doubleValue(dict.scale),
    seed: int64String(dict.seed),
    sizeText: w && h && w > 0 && h > 0 ? `${w} × ${h}` : null,
    clipSkip: null,
    loras: [],
    extraParameters: {},
    rawParameters: commentJSON.slice(0, 8000),
  };
  return isAIGenerationEmpty(meta) ? null : meta;
}

function parseInvokeAIMetadata(rawJSON: string): AIGenerationMetadata | null {
  let dict: Record<string, unknown>;
  try {
    const parsed = JSON.parse(rawJSON) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    dict = parsed as Record<string, unknown>;
  } catch {
    return null;
  }

  const modelObj =
    dict.model && typeof dict.model === 'object' && !Array.isArray(dict.model)
      ? (dict.model as Record<string, unknown>)
      : null;
  const w = intValue(dict.width);
  const h = intValue(dict.height);
  const meta: AIGenerationMetadata = {
    generator: 'InvokeAI',
    prompt: cleanString(dict.positive_prompt) ?? cleanString(dict.prompt),
    negativePrompt: cleanString(dict.negative_prompt),
    modelName: cleanString(modelObj?.name) ?? cleanString(dict.model_name),
    modelHash: null,
    sampler: cleanString(dict.scheduler) ?? cleanString(dict.sampler),
    scheduler: null,
    steps: intValue(dict.steps),
    cfgScale: doubleValue(dict.cfg_scale),
    seed: int64String(dict.seed),
    sizeText: w && h && w > 0 && h > 0 ? `${w} × ${h}` : null,
    clipSkip: null,
    loras: [],
    extraParameters: {},
    rawParameters: rawJSON.slice(0, 8000),
  };
  return isAIGenerationEmpty(meta) ? null : meta;
}

function parseMidjourneyDescription(desc: string): AIGenerationMetadata {
  let cleanPrompt = desc;
  const extraParameters: Record<string, string> = {};
  const jobIdx = cleanPrompt.indexOf('Job ID:');
  if (jobIdx >= 0) {
    const jobID = cleanPrompt.slice(jobIdx + 'Job ID:'.length).trim();
    if (jobID) extraParameters['Job ID'] = jobID;
    cleanPrompt = cleanPrompt.slice(0, jobIdx).trim();
  }
  let modelName: string | null = null;
  const vMatch = /--(?:v|version)\s+([0-9.]+)/i.exec(cleanPrompt);
  if (vMatch) {
    modelName = `Midjourney v${vMatch[1]}`;
  } else if (cleanPrompt.includes('--niji')) {
    modelName = 'Midjourney Niji';
  }
  const seedMatch = /--seed\s+(\d+)/i.exec(cleanPrompt);
  return {
    generator: 'Midjourney',
    prompt: cleanPrompt,
    negativePrompt: null,
    modelName,
    modelHash: null,
    sampler: null,
    scheduler: null,
    steps: null,
    cfgScale: null,
    seed: seedMatch ? seedMatch[1] : null,
    sizeText: null,
    clipSkip: null,
    loras: [],
    extraParameters,
    rawParameters: desc.slice(0, 8000),
  };
}

function parseGenericAIJSON(rawJSON: string): AIGenerationMetadata | null {
  let dict: Record<string, unknown>;
  try {
    const parsed = JSON.parse(rawJSON) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    dict = parsed as Record<string, unknown>;
  } catch {
    return null;
  }

  // SwarmUI `sui_image_params`
  if (dict.sui_image_params && typeof dict.sui_image_params === 'object' && !Array.isArray(dict.sui_image_params)) {
    const sui = dict.sui_image_params as Record<string, unknown>;
    const meta: AIGenerationMetadata = {
      generator: 'SwarmUI',
      prompt: cleanString(sui.prompt),
      negativePrompt: cleanString(sui.negativeprompt),
      modelName: cleanString(sui.model),
      modelHash: null,
      sampler: cleanString(sui.sampler),
      scheduler: cleanString(sui.scheduler),
      steps: intValue(sui.steps),
      cfgScale: doubleValue(sui.cfgscale),
      seed: int64String(sui.seed),
      sizeText: null,
      clipSkip: null,
      loras: [],
      extraParameters: {},
      rawParameters: rawJSON.slice(0, 8000),
    };
    if (!isAIGenerationEmpty(meta)) return meta;
  }

  // Draw Things JSON (`c` = prompt, `uc` = negative prompt)
  const cPrompt = cleanString(dict.c);
  if (cPrompt) {
    const meta: AIGenerationMetadata = {
      generator: 'Draw Things',
      prompt: cPrompt,
      negativePrompt: cleanString(dict.uc),
      modelName: cleanString(dict.model),
      modelHash: null,
      sampler: cleanString(dict.sampler),
      scheduler: null,
      steps: intValue(dict.steps),
      cfgScale: doubleValue(dict.scale),
      seed: int64String(dict.seed),
      sizeText: cleanString(dict.size),
      clipSkip: null,
      loras: [],
      extraParameters: {},
      rawParameters: rawJSON.slice(0, 8000),
    };
    if (!isAIGenerationEmpty(meta)) return meta;
  }

  // ComfyUI graph JSON inside EXIF UserComment
  const comfy = parseComfyUIPromptJSON(rawJSON);
  if (comfy) return comfy;

  // NovelAI JSON inside EXIF UserComment
  if ('uc' in dict || 'v4_prompt' in dict) {
    const nai = parseNovelAIMetadata(rawJSON, null);
    if (nai) return nai;
  }

  // Generic `prompt` JSON object
  const genericPrompt = cleanString(dict.prompt) ?? cleanString(dict.positive_prompt);
  if (genericPrompt) {
    const meta: AIGenerationMetadata = {
      generator: cleanString(dict.generator) ?? cleanString(dict.software) ?? 'AI 生成',
      prompt: genericPrompt,
      negativePrompt: cleanString(dict.negative_prompt) ?? cleanString(dict.uc),
      modelName: cleanString(dict.model),
      modelHash: null,
      sampler: cleanString(dict.sampler),
      scheduler: null,
      steps: intValue(dict.steps),
      cfgScale: doubleValue(dict.cfg_scale ?? dict.cfg ?? dict.scale),
      seed: int64String(dict.seed),
      sizeText: null,
      clipSkip: null,
      loras: [],
      extraParameters: {},
      rawParameters: rawJSON.slice(0, 8000),
    };
    if (!isAIGenerationEmpty(meta)) return meta;
  }

  return null;
}

function extractAIGenerationFromBag(
  pngChunks: Record<string, string>,
  tiff: ParsedTiffBag | null,
  xmpEntries: Record<string, string>,
  iptc: IptcBag,
): AIGenerationMetadata | null {
  const lowerPNG: Record<string, string> = {};
  for (const [k, v] of Object.entries(pngChunks)) {
    const lk = k.toLowerCase();
    if (!(lk in lowerPNG)) lowerPNG[lk] = v;
  }

  // A. Stable Diffusion WebUI (A1111 / Forge / reForge / Civitai) PNG `parameters`
  const paramsChunk = lowerPNG.parameters?.trim();
  if (paramsChunk) {
    if (paramsChunk.startsWith('{')) {
      const jsonParsed = parseGenericAIJSON(paramsChunk);
      if (jsonParsed) return jsonParsed;
    }
    const parsed = parseA1111Parameters(paramsChunk);
    if (parsed) return parsed;
  }

  // B. ComfyUI PNG `prompt` (API graph JSON)
  const promptChunk = lowerPNG.prompt?.trim();
  if (promptChunk && promptChunk.startsWith('{')) {
    const parsed = parseComfyUIPromptJSON(promptChunk);
    if (parsed) return parsed;
  }

  // C. NovelAI PNG (`Software` contains NovelAI or `Comment` JSON with `uc` / `v4_prompt`)
  const commentChunk = lowerPNG.comment?.trim();
  if (
    commentChunk &&
    commentChunk.startsWith('{') &&
    (lowerPNG.software?.toLowerCase().includes('novelai') ||
      commentChunk.includes('"uc"') ||
      commentChunk.includes('"v4_prompt"'))
  ) {
    const parsed = parseNovelAIMetadata(commentChunk, lowerPNG.description ?? null);
    if (parsed) return parsed;
  }

  // D. InvokeAI (`invokeai_metadata` or `sd-metadata`)
  const invokeChunk = (lowerPNG.invokeai_metadata ?? lowerPNG['sd-metadata'])?.trim();
  if (invokeChunk && invokeChunk.startsWith('{')) {
    const parsed = parseInvokeAIMetadata(invokeChunk);
    if (parsed) return parsed;
  }

  // E. Midjourney PNG `Description` + `Author` / `Job ID:`
  const descChunk = lowerPNG.description?.trim();
  if (descChunk) {
    const author = lowerPNG.author ?? '';
    if (
      author.toLowerCase().includes('midjourney') ||
      descChunk.includes('Job ID:') ||
      descChunk.includes('--v ') ||
      descChunk.includes('--ar ') ||
      descChunk.includes('--niji')
    ) {
      return parseMidjourneyDescription(descChunk);
    }
  }

  // F. SwarmUI / Draw Things / XMP / EXIF UserComment / TIFF ImageDescription / IPTC Caption
  const candidates: string[] = [];
  if (tiff?.userComment) candidates.push(tiff.userComment);
  if (xmpEntries['exif:UserComment']) candidates.push(xmpEntries['exif:UserComment']);
  if (xmpEntries['dc:description']) candidates.push(xmpEntries['dc:description']);
  if (tiff?.imageDescription) candidates.push(tiff.imageDescription);
  if (iptc.caption) candidates.push(iptc.caption);
  if (lowerPNG['xml:com.adobe.xmp']) {
    const pngXmp = lowerPNG['xml:com.adobe.xmp'];
    const extracted =
      extractXmlTagContent(pngXmp, 'exif:UserComment') ??
      extractXmlTagContent(pngXmp, 'dc:description');
    if (extracted) candidates.push(extracted);
  }

  for (const raw of candidates) {
    const trimmed = raw.trim();
    if (!trimmed) continue;

    if (trimmed.startsWith('{')) {
      const parsed = parseGenericAIJSON(trimmed);
      if (parsed) return parsed;
    }

    if (
      trimmed.includes('Steps:') ||
      trimmed.includes('Negative prompt:') ||
      trimmed.includes('Sampler:')
    ) {
      const parsed = parseA1111Parameters(trimmed);
      if (parsed) return parsed;
    }

    if (trimmed.includes('Job ID:') || trimmed.includes('--v ') || trimmed.includes('--niji')) {
      return parseMidjourneyDescription(trimmed);
    }
  }

  // G. Generic plain-text PNG `prompt` chunk
  if (promptChunk && !promptChunk.startsWith('{')) {
    return {
      generator: lowerPNG.software?.trim() || 'AI 生成',
      prompt: promptChunk,
      negativePrompt: lowerPNG.negative_prompt?.trim() || lowerPNG['negative prompt']?.trim() || null,
      modelName: null,
      modelHash: null,
      sampler: null,
      scheduler: null,
      steps: null,
      cfgScale: null,
      seed: null,
      sizeText: null,
      clipSkip: null,
      loras: [],
      extraParameters: {},
      rawParameters: promptChunk.slice(0, 8000),
    };
  }

  return null;
}

// MARK: - Main Public Entrypoint

export async function extractImageMetadata(
  bytes: Uint8Array,
  _mimeType?: string,
): Promise<ExtractedImageMetadata> {
  if (!bytes || bytes.byteLength < 8) {
    return { photoExif: null, aiGeneration: null };
  }

  const capped =
    bytes.byteLength > MAX_BINARY_SCAN_BYTES
      ? bytes.subarray(0, MAX_BINARY_SCAN_BYTES)
      : bytes;

  let bag: ParsedBinaryMetadata;

  if (isPng(capped)) {
    const png = await parsePngContainer(capped);
    const xmpStrings: string[] = [];
    for (const [k, v] of Object.entries(png.textChunks)) {
      if (k.toLowerCase() === 'xml:com.adobe.xmp' && v) {
        xmpStrings.push(v);
      }
    }
    bag = {
      tiffBag: png.tiffBag,
      xmpStrings,
      iptc: {},
      pngChunks: png.textChunks,
      colorProfile: png.colorProfile,
      bitDepth: png.bitDepth,
      dpiWidth: png.dpiWidth,
    };
  } else if (capped[0] === 0xff && capped[1] === 0xd8) {
    bag = parseJpegContainer(capped);
  } else if (
    capped.byteLength >= 12 &&
    readAscii(capped, 0, 4) === 'RIFF' &&
    readAscii(capped, 8, 4) === 'WEBP'
  ) {
    bag = parseWebPContainer(capped);
  } else {
    return { photoExif: null, aiGeneration: null };
  }

  const xmpEntries: Record<string, string> = {};
  for (const xml of bag.xmpStrings) {
    Object.assign(xmpEntries, parseXmpEntries(xml));
  }

  const tiff = bag.tiffBag;
  const rawDate = tiff?.dateTimeOriginal ?? tiff?.dateTimeDigitized ?? tiff?.tiffDateTime ?? null;
  const capturedAt = formatExifDate(rawDate, tiff?.offsetTimeOriginal ?? null);
  const exposureTime =
    tiff?.exposureSeconds != null ? formatExposureTime(tiff.exposureSeconds) : null;
  const meteringMode = tiff?.meteringMode != null ? meteringModeLabel(tiff.meteringMode) : null;
  const flashFired = tiff?.flash != null ? (tiff.flash & 1) !== 0 : null;
  const whiteBalance =
    tiff?.whiteBalance === 0 ? '自动' : tiff?.whiteBalance === 1 ? '手动' : null;
  const colorProfile =
    bag.colorProfile ?? (tiff?.colorSpace === 1 ? 'sRGB' : null);

  const photoExifCandidate: PhotoExifMetadata = {
    cameraMake: tiff?.cameraMake ?? null,
    cameraModel: tiff?.cameraModel ?? null,
    lensModel: tiff?.lensModel ?? xmpEntries['exifEX:LensModel'] ?? xmpEntries['aux:Lens'] ?? null,
    capturedAt,
    exposureTime,
    fNumber: tiff?.fNumber ?? null,
    iso: tiff?.iso ?? null,
    focalLengthMM: tiff?.focalLengthMM ?? null,
    focalLength35mm: tiff?.focalLength35mm ?? null,
    exposureBiasEV: tiff?.exposureBiasEV ?? null,
    meteringMode,
    flashFired,
    whiteBalance,
    colorProfile,
    bitDepth: bag.bitDepth ?? null,
    dpiWidth: tiff?.dpiWidth ?? bag.dpiWidth ?? null,
    software: tiff?.software ?? xmpEntries['xmp:CreatorTool'] ?? null,
    artist: tiff?.artist ?? bag.iptc.byline ?? xmpEntries['dc:creator'] ?? null,
    copyright: tiff?.copyright ?? bag.iptc.copyright ?? xmpEntries['dc:rights'] ?? null,
    latitude: tiff?.latitude ?? null,
    longitude: tiff?.longitude ?? null,
    altitudeMeters: tiff?.altitudeMeters ?? null,
  };

  const photoExif = isPhotoExifEmpty(photoExifCandidate) ? null : photoExifCandidate;
  const aiGeneration = extractAIGenerationFromBag(bag.pngChunks, tiff, xmpEntries, bag.iptc);

  return {
    photoExif,
    aiGeneration: aiGeneration && !isAIGenerationEmpty(aiGeneration) ? aiGeneration : null,
  };
}
