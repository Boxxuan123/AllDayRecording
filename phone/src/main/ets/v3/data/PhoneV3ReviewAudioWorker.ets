import { fileIo } from '@kit.CoreFileKit';
import { util, process } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';
import { decodeBase64Url } from '../../computer/ComputerTransferProtocol';

@Concurrent
export function prepareTransientReviewAudio(directory: string, name: string, encoded: string): string {
  try { fileIo.mkdirSync(directory); } catch (_error) { fileIo.statSync(directory); }
  if (encoded.length > 22369628) { throw new Error('试听音频过大'); }
  const bytes = decodeBase64Url(encoded);
  if (bytes.length === 0 || bytes.length > 16 * 1024 * 1024) { throw new Error('试听音频大小无效'); }
  const path = `${directory}/${name}.wav`;
  const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, bytes.buffer); } finally { fileIo.closeSync(file.fd); }
  return path;
}

interface AudioEntry {
  name: string;
  namespace: string;
  key: string;
  bytes: number;
  sha256: string;
  touched: number;
  holdUntil: number;
  response: DeviceV3ReviewAudioResponse;
}

// All directory scans, base64 conversion, hashes and IO execute in taskpool.
// Callers serialize this function; no database/network transaction crosses it.
@Concurrent
export async function reviewAudioFileTask(root: string, action: string, namespace: string,
  key: string, responseJson: string, pinnedJson: string, encodedAudio: string = ''): Promise<string> {
  const maxBytes: number = 64 * 1024 * 1024;
  const maxItem: number = 16 * 1024 * 1024;
  try { fileIo.mkdirSync(root); } catch (_error) { fileIo.statSync(root); }
  const indexPath = `${root}/index.json`;
  let entries: Array<AudioEntry> = [];
  try {
    if (fileIo.statSync(indexPath).size > 256 * 1024) { throw new Error('invalid index'); }
    entries = JSON.parse(fileIo.readTextSync(indexPath)) as Array<AudioEntry>;
    if (!Array.isArray(entries) || entries.length > 64) { entries = []; }
  } catch (_error) { entries = []; }
  const pins = JSON.parse(pinnedJson) as Array<string>;
  entries = entries.filter((entry: AudioEntry): boolean => /^[a-f0-9]{64}\.wav$/.test(entry.name) &&
    /^[a-f0-9]{64}$/.test(entry.key) && entry.bytes > 0 && entry.bytes <= maxItem);
  if (action === 'initialize') {
    // Lifecycle cleanup only: no directory walk on a click.
    const names = fileIo.listFileSync(root);
    for (const name of names) {
      if (name.endsWith('.part') || (/^[a-f0-9]{64}\.wav$/.test(name) && !entries.some((e: AudioEntry): boolean => e.name === name))) {
        try { fileIo.unlinkSync(`${root}/${name}`); } catch (_error) {}
      }
    }
  }
  let result: string = '';
  let ns: string = '';
  // Initialization/clear have no identity to hash. Native CryptoFramework does
  // not accept an empty update buffer on all supported devices.
  if (namespace.length > 0) {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(namespace) });
    ns = Array.from((await md.digest()).data).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
  }
  const entry = entries.find((e: AudioEntry): boolean => e.namespace === ns && e.key === key);
  if (action === 'read' && entry !== undefined) {
    try {
      const path = `${root}/${entry.name}`;
      if (fileIo.statSync(path).size !== entry.bytes) { throw new Error('cache length'); }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const bytes = new ArrayBuffer(entry.bytes);
      try { if (fileIo.readSync(file.fd, bytes) !== entry.bytes) { throw new Error('cache short read'); } }
      finally { fileIo.closeSync(file.fd); }
      const digest = cryptoFramework.createMd('SHA256');
      await digest.update({ data: new Uint8Array(bytes) });
      const actual = Array.from((await digest.digest()).data).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
      if (actual !== entry.sha256) { throw new Error('cache digest'); }
      entry.touched = Date.now(); entry.holdUntil = Date.now() + 30000;
      entry.response.local_audio_path = path;
      entry.response.local_worker_tid = process.tid;
      result = JSON.stringify(entry.response);
    } catch (_error) {
      try { fileIo.unlinkSync(`${root}/${entry.name}`); } catch (_ignored) {}
      entries = entries.filter((e: AudioEntry): boolean => e.name !== entry.name);
    }
  }
  if (action === 'write') {
    const response = JSON.parse(responseJson) as DeviceV3ReviewAudioResponse;
    if (response.audio_content_key !== key || !/^[a-f0-9]{64}$/.test(response.sha256 ?? '') ||
      response.byte_length === undefined || response.byte_length <= 0 || response.byte_length > maxItem ||
      encodedAudio.length > Math.ceil(maxItem * 4 / 3) + 4) { throw new Error('音频缓存描述无效'); }
    let encoded = encodedAudio.replace(/-/g, '+').replace(/_/g, '/');
    while (encoded.length % 4 !== 0) { encoded += '='; }
    const bytes = new util.Base64Helper().decodeSync(encoded);
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: bytes });
    const actual = Array.from((await digest.digest()).data).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
    if (bytes.length !== response.byte_length || actual !== response.sha256) { throw new Error('试听音频不完整，请重试'); }
    const nameDigest = cryptoFramework.createMd('SHA256');
    await nameDigest.update({ data: new util.TextEncoder().encodeInto(`${ns}:${key}`) });
    const name = Array.from((await nameDigest.digest()).data).map((b: number): string => b.toString(16).padStart(2, '0')).join('') + '.wav';
    const path = `${root}/${name}`;
    const temp = `${path}.part`;
    entries.sort((a: AudioEntry, b: AudioEntry): number => a.touched - b.touched);
    let used = entries.reduce((sum: number, e: AudioEntry): number => sum + e.bytes, 0);
    const victims: Array<string> = [];
    for (const old of entries) {
      if (used + bytes.length <= maxBytes && entries.length - victims.length < 48) { break; }
      if (pins.indexOf(`${root}/${old.name}`) >= 0 || old.holdUntil > Date.now()) { continue; }
      fileIo.unlinkSync(`${root}/${old.name}`);
      used -= old.bytes; victims.push(old.name);
    }
    entries = entries.filter((e: AudioEntry): boolean => victims.indexOf(e.name) < 0);
    if (used + bytes.length > maxBytes || entries.length >= 48) { throw new Error('试听缓存空间暂不足，请稍后重试'); }
    try {
      const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        if (fileIo.writeSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('试听缓存写入不完整'); }
        fileIo.fsyncSync(file.fd);
      } finally { fileIo.closeSync(file.fd); }
      fileIo.renameSync(temp, path);
    } finally { try { fileIo.unlinkSync(temp); } catch (_error) {} }
    response.data_base64url = ''; response.local_audio_path = path;
    response.local_worker_tid = process.tid;
    entries = entries.filter((e: AudioEntry): boolean => e.name !== name);
    entries.push({ name: name, namespace: ns, key: key, bytes: bytes.length, sha256: actual,
      touched: Date.now(), holdUntil: Date.now() + 30000, response: response });
    result = JSON.stringify(response);
  }
  entries.sort((a: AudioEntry, b: AudioEntry): number => a.touched - b.touched);
  let total = entries.reduce((sum: number, e: AudioEntry): number => sum + e.bytes, 0);
  const retained: Array<AudioEntry> = [];
  let count = entries.length;
  for (const item of entries) {
    const pinned = pins.indexOf(`${root}/${item.name}`) >= 0;
    const obsolete = action === 'clear' || (namespace.length > 0 && item.namespace !== ns);
    const evict = obsolete || (item.holdUntil < Date.now() && (count > 48 || total > maxBytes));
    if (evict && !pinned) {
      try { fileIo.unlinkSync(`${root}/${item.name}`); } catch (_error) {}
      total -= item.bytes; count -= 1;
    } else { retained.push(item); }
  }
  const manifest = JSON.stringify(retained);
  const index = fileIo.openSync(`${indexPath}.part`, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(index.fd, manifest); fileIo.fsyncSync(index.fd); }
  finally { fileIo.closeSync(index.fd); }
  fileIo.renameSync(`${indexPath}.part`, indexPath);
  return result;
}
