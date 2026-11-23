/**
 * Incremental, chunk-boundary-safe stdio frame parser for MCP JSON-RPC 2.0 streams.
 * 100% pure `Uint8Array` (ZERO `node:*` imports — works identically in Node and Workers tests).
 *
 * Supports both:
 * - Standard MCP newline-delimited JSON (`ndjson`) for objects (`{...}`) and batch arrays (`[...]`)
 * - LSP-style `Content-Length: <bytes>\r\n\r\n<body>` (and `\n\n` fallback)
 *
 * Partial `Content-Length` headers split across arbitrary stream chunks are preserved intact
 * rather than misclassified as NDJSON lines.
 */

export type MCPStdioFraming = 'ndjson' | 'contentLength';

export type MCPStdioFrameEvent =
  | { type: 'message'; payload: Uint8Array; framing: MCPStdioFraming }
  | { type: 'invalidFrame'; reason: string; framing: MCPStdioFraming };

const MAX_HEADER_BYTES = 8 * 1024;
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.byteLength === 0) return b.slice();
  if (b.byteLength === 0) return a;
  const out = new Uint8Array(a.byteLength + b.byteLength);
  out.set(a, 0);
  out.set(b, a.byteLength);
  return out;
}

function isBlankByte(b: number): boolean {
  return b === 0x20 || b === 0x09 || b === 0x0d || b === 0x0a;
}

function isHeaderLeadByte(b: number): boolean {
  return (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a);
}

function trimWhitespace(data: Uint8Array): Uint8Array {
  let start = 0;
  let end = data.byteLength;
  while (start < end && isBlankByte(data[start])) start++;
  while (end > start && isBlankByte(data[end - 1])) end--;
  return data.slice(start, end);
}

function indexOfSequence(haystack: Uint8Array, needle: readonly number[]): number {
  const nLen = needle.length;
  const limit = haystack.byteLength - nLen;
  outer: for (let i = 0; i <= limit; i++) {
    for (let j = 0; j < nLen; j++) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

const CRLF_CRLF = [0x0d, 0x0a, 0x0d, 0x0a] as const;
const LF_LF = [0x0a, 0x0a] as const;

export class MCPStdioFrameParser {
  public readonly maxFrameBytes: number;
  private buffer: Uint8Array = new Uint8Array(0);

  constructor(maxFrameBytes = 32 * 1024 * 1024) {
    this.maxFrameBytes = Math.max(1024, Math.trunc(maxFrameBytes));
  }

  append(chunk: Uint8Array): MCPStdioFrameEvent[] {
    if (!chunk || chunk.byteLength === 0) return [];
    this.buffer = concatBytes(this.buffer, chunk);
    return this.drainAvailable();
  }

  finishEOF(): MCPStdioFrameEvent[] {
    const events = this.drainAvailable();
    const remaining = trimWhitespace(this.buffer);
    this.buffer = new Uint8Array(0);
    if (remaining.byteLength > 0) {
      const first = remaining[0];
      if (first === 0x7b || first === 0x5b) {
        events.push({ type: 'message', payload: remaining, framing: 'ndjson' });
      } else {
        events.push({
          type: 'invalidFrame',
          reason: 'Incomplete trailing stdio frame at EOF',
          framing: 'ndjson',
        });
      }
    }
    return events;
  }

  static encode(payload: Uint8Array, framing: MCPStdioFraming): Uint8Array {
    if (framing === 'ndjson') {
      const out = new Uint8Array(payload.byteLength + 1);
      out.set(payload, 0);
      out[payload.byteLength] = 0x0a;
      return out;
    }
    const header = utf8Encoder.encode(`Content-Length: ${payload.byteLength}\r\n\r\n`);
    const out = new Uint8Array(header.byteLength + payload.byteLength);
    out.set(header, 0);
    out.set(payload, header.byteLength);
    return out;
  }

  private trimLeadingBlankBytes(): void {
    let idx = 0;
    while (idx < this.buffer.byteLength && isBlankByte(this.buffer[idx])) {
      idx++;
    }
    if (idx > 0) {
      this.buffer = this.buffer.slice(idx);
    }
  }

  private findHeaderTerminator(): { start: number; end: number; lineSep: string } | null {
    const crlfIdx = indexOfSequence(this.buffer, CRLF_CRLF);
    const lfIdx = indexOfSequence(this.buffer, LF_LF);
    if (crlfIdx >= 0 && lfIdx >= 0) {
      return crlfIdx <= lfIdx
        ? { start: crlfIdx, end: crlfIdx + 4, lineSep: '\r\n' }
        : { start: lfIdx, end: lfIdx + 2, lineSep: '\n' };
    }
    if (crlfIdx >= 0) return { start: crlfIdx, end: crlfIdx + 4, lineSep: '\r\n' };
    if (lfIdx >= 0) return { start: lfIdx, end: lfIdx + 2, lineSep: '\n' };
    return null;
  }

  private drainAvailable(): MCPStdioFrameEvent[] {
    const events: MCPStdioFrameEvent[] = [];

    while (true) {
      this.trimLeadingBlankBytes();
      if (this.buffer.byteLength === 0) break;

      const firstByte = this.buffer[0];

      // JSON object ('{') or JSON-RPC batch array ('[') -> NDJSON line mode
      if (firstByte === 0x7b || firstByte === 0x5b) {
        const nl = this.buffer.indexOf(0x0a);
        if (nl < 0) break;
        const rawLine = this.buffer.slice(0, nl);
        this.buffer = this.buffer.slice(nl + 1);
        const trimmed = trimWhitespace(rawLine);
        if (trimmed.byteLength > 0) {
          events.push({ type: 'message', payload: trimmed, framing: 'ndjson' });
        }
        continue;
      }

      // ASCII header start (e.g. `Content-Length:` / `Content-Type:`) -> wait for full header block
      if (isHeaderLeadByte(firstByte)) {
        const term = this.findHeaderTerminator();
        if (!term) {
          if (this.buffer.byteLength > MAX_HEADER_BYTES) {
            const nl = this.buffer.indexOf(0x0a);
            this.buffer = nl >= 0 ? this.buffer.slice(nl + 1) : new Uint8Array(0);
            events.push({
              type: 'invalidFrame',
              reason: `Malformed stdio header exceeds ${MAX_HEADER_BYTES} bytes`,
              framing: 'contentLength',
            });
            continue;
          }
          break; // Wait for more header bytes
        }

        const headerBytes = this.buffer.slice(0, term.start);
        let headerText: string;
        try {
          headerText = utf8Decoder.decode(headerBytes);
        } catch {
          this.buffer = this.buffer.slice(term.end);
          events.push({
            type: 'invalidFrame',
            reason: 'Non-UTF8 Content-Length header',
            framing: 'contentLength',
          });
          continue;
        }

        let parsedLength: number | null = null;
        for (const line of headerText.split(term.lineSep)) {
          const colon = line.indexOf(':');
          if (colon < 0) continue;
          const key = line.slice(0, colon).trim().toLowerCase();
          if (key === 'content-length') {
            const rawVal = line.slice(colon + 1).trim();
            if (/^\d+$/.test(rawVal)) {
              parsedLength = Number.parseInt(rawVal, 10);
            }
          }
        }

        if (parsedLength === null || !Number.isSafeInteger(parsedLength) || parsedLength < 0) {
          this.buffer = this.buffer.slice(term.end);
          events.push({
            type: 'invalidFrame',
            reason: 'Missing or invalid Content-Length header',
            framing: 'contentLength',
          });
          continue;
        }

        if (parsedLength > this.maxFrameBytes) {
          this.buffer = this.buffer.slice(term.end);
          events.push({
            type: 'invalidFrame',
            reason: `Content-Length ${parsedLength} exceeds limit ${this.maxFrameBytes}`,
            framing: 'contentLength',
          });
          continue;
        }

        const bodyStart = term.end;
        const bodyEnd = bodyStart + parsedLength;
        if (this.buffer.byteLength < bodyEnd) {
          break; // Wait for full framed body
        }

        const payload = this.buffer.slice(bodyStart, bodyEnd);
        this.buffer = this.buffer.slice(bodyEnd);
        events.push({ type: 'message', payload, framing: 'contentLength' });
        continue;
      }

      // Unexpected non-JSON, non-header line: consume through newline and emit to JSON parser
      const nl = this.buffer.indexOf(0x0a);
      if (nl < 0) {
        if (this.buffer.byteLength > MAX_HEADER_BYTES) {
          this.buffer = new Uint8Array(0);
          events.push({
            type: 'invalidFrame',
            reason: 'Unrecognized stdio frame',
            framing: 'ndjson',
          });
        }
        break;
      }
      const garbage = trimWhitespace(this.buffer.slice(0, nl));
      this.buffer = this.buffer.slice(nl + 1);
      if (garbage.byteLength > 0) {
        events.push({ type: 'message', payload: garbage, framing: 'ndjson' });
      }
    }

    return events;
  }
}
