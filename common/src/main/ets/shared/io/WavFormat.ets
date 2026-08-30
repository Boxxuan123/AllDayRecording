export const PCM_SAMPLE_RATE_HZ: number = 16000;
export const PCM_CHANNEL_COUNT: number = 1;
export const PCM_BITS_PER_SAMPLE: number = 16;
export const PCM_BYTES_PER_SAMPLE: number = PCM_BITS_PER_SAMPLE / 8;
export const WAV_HEADER_BYTES: number = 44;

export type BufferWriteOperation = (buffer: ArrayBuffer) => number;

export function createPcmWavHeader(pcmBytes: number): ArrayBuffer {
  const buffer = new ArrayBuffer(WAV_HEADER_BYTES);
  const header = new Uint8Array(buffer);
  writeAscii(header, 0, 'RIFF');
  writeUint32Le(header, 4, 36 + pcmBytes);
  writeAscii(header, 8, 'WAVE');
  writeAscii(header, 12, 'fmt ');
  writeUint32Le(header, 16, 16);
  writeUint16Le(header, 20, 1);
  writeUint16Le(header, 22, PCM_CHANNEL_COUNT);
  writeUint32Le(header, 24, PCM_SAMPLE_RATE_HZ);
  writeUint32Le(header, 28, PCM_SAMPLE_RATE_HZ * PCM_CHANNEL_COUNT * PCM_BYTES_PER_SAMPLE);
  writeUint16Le(header, 32, PCM_CHANNEL_COUNT * PCM_BYTES_PER_SAMPLE);
  writeUint16Le(header, 34, PCM_BITS_PER_SAMPLE);
  writeAscii(header, 36, 'data');
  writeUint32Le(header, 40, pcmBytes);
  return buffer;
}

export function writeEntireBuffer(buffer: ArrayBuffer, writeOperation: BufferWriteOperation): void {
  let remaining = buffer;
  while (remaining.byteLength > 0) {
    const written = writeOperation(remaining);
    if (written <= 0) {
      throw new Error('写入 WAV 文件失败');
    }
    if (written === remaining.byteLength) {
      return;
    }
    remaining = remaining.slice(written);
  }
}

function writeAscii(target: Uint8Array, offset: number, value: string): void {
  for (let index = 0; index < value.length; index += 1) {
    target[offset + index] = value.charCodeAt(index);
  }
}

function writeUint16Le(target: Uint8Array, offset: number, value: number): void {
  target[offset] = value & 0xff;
  target[offset + 1] = (value >>> 8) & 0xff;
}

function writeUint32Le(target: Uint8Array, offset: number, value: number): void {
  target[offset] = value & 0xff;
  target[offset + 1] = (value >>> 8) & 0xff;
  target[offset + 2] = (value >>> 16) & 0xff;
  target[offset + 3] = (value >>> 24) & 0xff;
}
