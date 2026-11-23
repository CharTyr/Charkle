function readAscii(bytes: Uint8Array, start: number, end: number): string {
  let out = '';
  for (let i = start; i < end && i < bytes.byteLength; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

/**
 * Pure-TS 48-bar audio waveform & duration extractor (ZERO Node/sharp imports).
 * Parses RIFF/WAVE PCM buffers directly; falls back to chunked RMS energy for compressed formats.
 */
export function extractAudioWaveform(
  buffer: Uint8Array,
  fileName: string,
  barCount = 48,
): { durationSeconds: number | null; waveformPeaks: number[] } {
  const count = Math.max(16, Math.min(64, barCount));
  const ext = fileName.toLowerCase().split('.').pop() ?? '';
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);

  // Parse RIFF/WAVE PCM directly for exact peaks & duration
  if (
    ext === 'wav' &&
    buffer.byteLength >= 44 &&
    readAscii(buffer, 0, 4) === 'RIFF' &&
    readAscii(buffer, 8, 12) === 'WAVE'
  ) {
    let offset = 12;
    let numChannels = 1;
    let sampleRate = 44100;
    let bitsPerSample = 16;
    let dataStart = -1;
    let dataSize = 0;

    while (offset + 8 <= buffer.byteLength) {
      const chunkId = readAscii(buffer, offset, offset + 4);
      const chunkSize = view.getUint32(offset + 4, true);
      const bodyStart = offset + 8;
      if (chunkId === 'fmt ' && bodyStart + 16 <= buffer.byteLength) {
        numChannels = Math.max(1, view.getUint16(bodyStart + 2, true));
        sampleRate = Math.max(1, view.getUint32(bodyStart + 4, true));
        bitsPerSample = Math.max(8, view.getUint16(bodyStart + 14, true));
      } else if (chunkId === 'data') {
        dataStart = bodyStart;
        dataSize = Math.min(chunkSize, buffer.byteLength - bodyStart);
        break;
      }
      offset = bodyStart + chunkSize + (chunkSize % 2);
    }

    if (dataStart >= 0 && dataSize > 0) {
      const bytesPerSample = Math.max(1, Math.floor(bitsPerSample / 8));
      const frameBytes = bytesPerSample * numChannels;
      const totalFrames = Math.floor(dataSize / frameBytes);
      const durationSeconds =
        totalFrames > 0 ? Math.round((totalFrames / sampleRate) * 100) / 100 : null;
      const framesPerBar = Math.max(1, Math.floor(totalFrames / count));
      const rawPeaks: number[] = [];

      for (let bar = 0; bar < count; bar++) {
        const startFrame = bar * framesPerBar;
        const endFrame = Math.min(totalFrames, startFrame + framesPerBar);
        const step = Math.max(1, Math.floor((endFrame - startFrame) / 256));
        let maxAmp = 0;
        for (let f = startFrame; f < endFrame; f += step) {
          const bytePos = dataStart + f * frameBytes;
          if (bytePos + bytesPerSample > buffer.byteLength) break;
          let sample = 0;
          if (bitsPerSample === 16) {
            sample = Math.abs(view.getInt16(bytePos, true)) / 32768;
          } else if (bitsPerSample === 8) {
            sample = Math.abs(buffer[bytePos] - 128) / 128;
          } else if (bitsPerSample === 24 && bytePos + 3 <= buffer.byteLength) {
            let v = buffer[bytePos] | (buffer[bytePos + 1] << 8) | (buffer[bytePos + 2] << 16);
            if (v & 0x800000) v |= ~0xffffff;
            sample = Math.abs(v) / 8388608;
          } else if (bitsPerSample === 32 && bytePos + 4 <= buffer.byteLength) {
            sample = Math.min(1, Math.abs(view.getFloat32(bytePos, true)));
          }
          if (sample > maxAmp) maxAmp = sample;
        }
        rawPeaks.push(maxAmp);
      }

      const maxVal = Math.max(...rawPeaks, 0.001);
      const normalized = rawPeaks.map(
        (v) => Math.round(Math.max(0.08, Math.min(1, v / maxVal)) * 1000) / 1000,
      );
      return { durationSeconds, waveformPeaks: normalized };
    }
  }

  // Generic deterministic chunk-variance envelope for MP3/M4A/OGG/FLAC/AAC/etc.
  if (buffer.byteLength < count * 2) {
    const fallback = Array.from(
      { length: count },
      (_, i) => Math.round((0.25 + 0.65 * Math.abs(Math.sin(i * 0.35))) * 1000) / 1000,
    );
    return { durationSeconds: null, waveformPeaks: fallback };
  }

  const headerSkip = Math.min(Math.floor(buffer.byteLength * 0.05), 4096);
  const bodyLen = Math.max(count, buffer.byteLength - headerSkip);
  const chunkLen = Math.floor(bodyLen / count);
  const energies: number[] = [];

  for (let bar = 0; bar < count; bar++) {
    const start = headerSkip + bar * chunkLen;
    const end = Math.min(buffer.byteLength, start + chunkLen);
    const step = Math.max(1, Math.floor((end - start) / 256));
    let sumSq = 0;
    let n = 0;
    for (let i = start; i < end; i += step) {
      const centered = (buffer[i] - 127.5) / 127.5;
      sumSq += centered * centered;
      n++;
    }
    energies.push(n > 0 ? Math.sqrt(sumSq / n) : 0.2);
  }

  const minE = Math.min(...energies);
  const maxE = Math.max(...energies);
  const span = Math.max(0.05, maxE - minE);
  const peaks = energies.map((e, i) => {
    const scaled = 0.16 + 0.78 * ((e - minE) / span);
    const modulation =
      span < 0.08 ? 0.72 + 0.28 * Math.abs(Math.sin(i * 0.42 + e * 9)) : 1;
    return Math.round(Math.max(0.1, Math.min(1, scaled * modulation)) * 1000) / 1000;
  });

  const approxDuration =
    ext === 'mp3' || ext === 'm4a' || ext === 'aac' || ext === 'ogg' || ext === 'opus'
      ? Math.max(1, Math.round((buffer.byteLength / 16000) * 10) / 10)
      : null;

  return { durationSeconds: approxDuration, waveformPeaks: peaks };
}
