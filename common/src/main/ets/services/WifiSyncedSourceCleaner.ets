import { fileIo } from '@kit.CoreFileKit';

export const WIFI_SOURCE_DELETED: string = 'deleted';
export const WIFI_SOURCE_ALREADY_ABSENT: string = 'already_absent';

export interface WifiVerifiedSourceFile {
  fileName: string;
  path: string;
  relativePath: string;
  size: number;
  sha256: string;
}

export interface WifiSourceCleanupFileInfo {
  size: number;
  isFile: boolean;
}

export interface WifiSourceCleanupFileSystem {
  exists(path: string): boolean;
  stat(path: string): WifiSourceCleanupFileInfo;
  unlink(path: string): void;
}

class CoreWifiSourceCleanupFileSystem implements WifiSourceCleanupFileSystem {
  exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      throw cleanupFileError(error);
    }
  }

  stat(path: string): WifiSourceCleanupFileInfo {
    try {
      const stat = fileIo.statSync(path);
      return {
        size: stat.size,
        isFile: stat.isFile()
      };
    } catch (error) {
      throw cleanupFileError(error);
    }
  }

  unlink(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (error) {
      throw cleanupFileError(error);
    }
  }
}

const CORE_WIFI_SOURCE_CLEANUP_FILE_SYSTEM: WifiSourceCleanupFileSystem =
  new CoreWifiSourceCleanupFileSystem();

export function deleteVerifiedWifiSource(filesDirectory: string, source: WifiVerifiedSourceFile,
  currentSha256: string,
  fileSystem: WifiSourceCleanupFileSystem = CORE_WIFI_SOURCE_CLEANUP_FILE_SYSTEM): string {
  const expectedPath = `${filesDirectory}/${source.relativePath}`;
  if (!isSafeCleanupRelativePath(source.relativePath) || source.path !== expectedPath) {
    throw new Error('拒绝删除录音目录之外的 Wi-Fi 源文件');
  }
  if (!fileSystem.exists(source.path)) {
    return WIFI_SOURCE_ALREADY_ABSENT;
  }
  const stat = fileSystem.stat(source.path);
  if (!stat.isFile || stat.size !== source.size) {
    throw new Error('手表源文件类型或大小在 Wi-Fi 确认后发生变化');
  }
  if (!isSha256(source.sha256) || !isSha256(currentSha256) ||
    source.sha256.toLowerCase() !== currentSha256.toLowerCase()) {
    throw new Error('手表源文件内容在 Wi-Fi 确认后发生变化');
  }
  fileSystem.unlink(source.path);
  return WIFI_SOURCE_DELETED;
}

function isSafeCleanupRelativePath(relativePath: string): boolean {
  if (relativePath.length === 0 || relativePath.startsWith('/') || relativePath.includes('..') ||
    relativePath.includes('\\')) {
    return false;
  }
  const lowerPath = relativePath.toLowerCase();
  return lowerPath.endsWith('.wav') || lowerPath.endsWith('.m4a');
}

function isSha256(value: string): boolean {
  return /^[0-9a-fA-F]{64}$/.test(value);
}

function cleanupFileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
