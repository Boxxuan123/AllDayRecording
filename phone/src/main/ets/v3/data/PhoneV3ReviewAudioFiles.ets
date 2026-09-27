import { fileIo } from '@kit.CoreFileKit';
import { DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';

export interface AudioEntry {
  name: string;
  namespace: string;
  key: string;
  bytes: number;
  sha256: string;
  touched: number;
  holdUntil: number;
  response: DeviceV3ReviewAudioResponse;
}

interface CacheFileError { code?: number; }

// CoreFileKit BusinessError 13900002 is ENOENT in the installed SDK.
export function removeDerivedFile(path: string): void {
  try { fileIo.unlinkSync(path); }
  catch (error) {
    if ((error as CacheFileError).code !== 13900002) { throw error as Error; }
  }
}

export function saveAudioIndex(indexPath: string, entries: Array<AudioEntry>): void {
  const manifest = JSON.stringify(entries);
  const index = fileIo.openSync(`${indexPath}.part`, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(index.fd, manifest); fileIo.fsyncSync(index.fd); }
  finally { fileIo.closeSync(index.fd); }
  fileIo.renameSync(`${indexPath}.part`, indexPath);
}

