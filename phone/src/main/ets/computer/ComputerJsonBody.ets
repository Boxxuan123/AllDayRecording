import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';

export const COMPUTER_JSON_MAX_BYTES: number = 32 * 1024 * 1024;

// Request binary data: some NetworkKit versions return gzip bytes unchanged.
// Magic detection also accepts a platform that already decoded Content-Encoding.
export async function computerJsonText(value: string | Object | ArrayBuffer): Promise<string> {
  if (typeof value === 'string') { return value; }
  if (!(value instanceof ArrayBuffer)) { return JSON.stringify(value); }
  if (value.byteLength > COMPUTER_JSON_MAX_BYTES) { throw new Error('电脑 JSON 响应超过大小限制'); }
  let bytes = new Uint8Array(value);
  if (bytes.length >= 2 && bytes[0] === 31 && bytes[1] === 139) {
    if (bytes.length < 18) { throw new Error('电脑 gzip 响应不完整'); }
    const size = new DataView(value).getUint32(bytes.length - 4, true);
    if (size === 0 || size > COMPUTER_JSON_MAX_BYTES) { throw new Error('电脑 gzip 解压大小无效'); }
    const output = new ArrayBuffer(size);
    const zip = await zlib.createZip();
    const stream: zlib.ZStream = { nextIn: value, availableIn: value.byteLength,
      nextOut: output, availableOut: size };
    const initialized = await zip.inflateInit2(stream, 31);
    if (initialized !== zlib.ReturnStatus.OK) { throw new Error('电脑 gzip 解压初始化失败'); }
    try {
      const result = await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
      const finalStream = await zip.getZStream();
      if (result !== zlib.ReturnStatus.STREAM_END || finalStream.totalOut !== size || finalStream.availableIn !== 0) {
        throw new Error('电脑 gzip 响应校验失败');
      }
      bytes = new Uint8Array(output);
    } finally { await zip.inflateEnd({}); }
  }
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}
