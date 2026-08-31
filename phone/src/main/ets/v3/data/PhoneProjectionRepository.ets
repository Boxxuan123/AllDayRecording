import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import {
  DeviceV3Change,
  DeviceV3ClientOperation,
  DeviceV3OperationReceipt
} from '../../computer/ComputerTransferProtocol';
import { V3_PROJECTION_VERSION } from '../contracts/V3ContractModels';
import {
  PhonePendingOperation,
  PhoneProjectionStorage,
  clearRebuildableProjection
} from './PhoneSyncProjection';

const DATABASE_NAME: string = 'phone_v3_projection.db';
const SCHEMA_VERSION: number = 2;
const TABLES: Array<string> = [
  'projection_recordings', 'projection_audio_assets', 'projection_processing_runs',
  'projection_utterances', 'projection_review_items'
];
const CREATE_STATEMENTS: Array<string> = [
  `CREATE TABLE IF NOT EXISTS projection_recordings (
    resource_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS projection_audio_assets (
    resource_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS projection_processing_runs (
    resource_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS projection_utterances (
    resource_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS projection_review_items (
    resource_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS projection_tombstones (
    resource_type TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL,
    updated_at INTEGER NOT NULL, PRIMARY KEY(resource_type, resource_id))`,
  `CREATE TABLE IF NOT EXISTS sync_state (
    singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1), projection_version INTEGER NOT NULL,
    cursor TEXT NOT NULL, last_server_time TEXT NOT NULL, last_error TEXT NOT NULL,
    last_attempt_at INTEGER NOT NULL, last_success_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS outbox (
    operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL, base_revision INTEGER,
    payload_json TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS conflicts (
    operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
    error_json TEXT NOT NULL, created_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS local_audio_links (
    session_key TEXT NOT NULL, local_path TEXT NOT NULL, sha256 TEXT NOT NULL,
    upload_status TEXT NOT NULL, updated_at INTEGER NOT NULL,
    PRIMARY KEY(session_key, local_path))`,
  `INSERT OR IGNORE INTO sync_state (
    singleton_id, projection_version, cursor, last_server_time, last_error,
    last_attempt_at, last_success_at) VALUES (1, 1, 'cursor-0', '', '', 0, 0)`
];
const VERSION_2_STATEMENTS: Array<string> = [
  'ALTER TABLE sync_state ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0'
];

export interface PhoneProjectionStatus {
  cursor: string;
  last_server_time: string;
  last_error: string;
  pending_operations: number;
  max_attempt_count: number;
  retry_count: number;
}

export class PhoneProjectionRepository implements PhoneProjectionStorage {
  private store: relationalStore.RdbStore;

  private constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  static async open(context: common.UIAbilityContext): Promise<PhoneProjectionRepository> {
    const config: relationalStore.StoreConfig = {
      name: DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S2
    };
    const store = await relationalStore.getRdbStore(context, config);
    await migrate(store);
    return new PhoneProjectionRepository(store);
  }

  async beginTransaction(): Promise<void> {
    this.store.beginTransaction();
  }

  async commit(): Promise<void> {
    this.store.commit();
  }

  async rollback(): Promise<void> {
    this.store.rollBack();
  }

  async enqueue(operation: DeviceV3ClientOperation): Promise<void> {
    await this.store.executeSql(
      `INSERT OR IGNORE INTO outbox (
        operation_id, kind, base_revision, payload_json, attempt_count, last_error, created_at)
       VALUES (?, ?, ?, ?, 0, '', ?)`,
      [operation.operation_id, operation.kind, operation.base_revision,
        JSON.stringify(operation.payload), Date.now()]);
  }

  async pendingOperations(limit: number = 500): Promise<Array<PhonePendingOperation>> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) {
      throw new Error('Phone outbox 查询上限无效');
    }
    const result = await this.store.querySql(
      `SELECT operation_id, kind, base_revision, payload_json, attempt_count
       FROM outbox ORDER BY created_at, operation_id LIMIT ?`, [limit]);
    const operations: Array<PhonePendingOperation> = [];
    try {
      while (result.goToNextRow()) {
        const baseIndex = result.getColumnIndex('base_revision');
        operations.push({
          operation_id: result.getString(result.getColumnIndex('operation_id')),
          kind: result.getString(result.getColumnIndex('kind')),
          base_revision: result.isColumnNull(baseIndex) ? null : result.getLong(baseIndex),
          payload: JSON.parse(result.getString(result.getColumnIndex('payload_json'))) as Object,
          attempt_count: result.getLong(result.getColumnIndex('attempt_count'))
        });
      }
    } finally {
      result.close();
    }
    return operations;
  }

  async currentCursor(): Promise<string> {
    const result = await this.store.querySql('SELECT cursor FROM sync_state WHERE singleton_id = 1');
    try {
      if (!result.goToNextRow()) {
        throw new Error('Phone V3 sync_state 缺失');
      }
      return result.getString(result.getColumnIndex('cursor'));
    } finally {
      result.close();
    }
  }

  async status(): Promise<PhoneProjectionStatus> {
    const result = await this.store.querySql(
      `SELECT cursor, last_server_time, last_error, retry_count,
       (SELECT COUNT(*) FROM outbox) AS pending_operations,
       (SELECT COALESCE(MAX(attempt_count), 0) FROM outbox) AS max_attempt_count
       FROM sync_state WHERE singleton_id = 1`);
    try {
      if (!result.goToNextRow()) {
        throw new Error('Phone V3 sync_state 缺失');
      }
      return {
        cursor: result.getString(result.getColumnIndex('cursor')),
        last_server_time: result.getString(result.getColumnIndex('last_server_time')),
        last_error: result.getString(result.getColumnIndex('last_error')),
        pending_operations: result.getLong(result.getColumnIndex('pending_operations')),
        max_attempt_count: result.getLong(result.getColumnIndex('max_attempt_count')),
        retry_count: result.getLong(result.getColumnIndex('retry_count'))
      };
    } finally {
      result.close();
    }
  }

  async recordingPayloads(): Promise<Array<string>> {
    const result = await this.store.querySql(
      'SELECT payload_json FROM projection_recordings ORDER BY updated_at DESC, resource_id');
    const values: Array<string> = [];
    try {
      while (result.goToNextRow()) {
        values.push(result.getString(result.getColumnIndex('payload_json')));
      }
    } finally {
      result.close();
    }
    return values;
  }

  async latestProcessingPayload(): Promise<string | null> {
    const result = await this.store.querySql(
      `SELECT payload_json FROM projection_processing_runs
       ORDER BY updated_at DESC, resource_id LIMIT 1`);
    try {
      if (!result.goToNextRow()) {
        return null;
      }
      return result.getString(result.getColumnIndex('payload_json'));
    } finally {
      result.close();
    }
  }

  async linkLocalAudio(sessionKey: string, localPath: string, sha256: string,
    uploadStatus: string): Promise<void> {
    await this.store.executeSql(
      `INSERT INTO local_audio_links (session_key, local_path, sha256, upload_status, updated_at)
       VALUES (?, ?, ?, ?, ?) ON CONFLICT(session_key, local_path) DO UPDATE SET
       sha256 = excluded.sha256,
       upload_status = excluded.upload_status, updated_at = excluded.updated_at`,
      [sessionKey, localPath, sha256, uploadStatus, Date.now()]);
  }

  async markSyncFailure(message: string): Promise<void> {
    const text = message.substring(0, 1000);
    this.store.beginTransaction();
    try {
      await this.store.executeSql(
        'UPDATE outbox SET attempt_count = attempt_count + 1, last_error = ?', [text]);
      await this.store.executeSql(
        `UPDATE sync_state SET last_error = ?, last_attempt_at = ?,
         retry_count = retry_count + 1 WHERE singleton_id = 1`,
        [text, Date.now()]);
      this.store.commit();
    } catch (error) {
      this.store.rollBack();
      throw repositoryError(error as Object);
    }
  }

  async rebuildFromComputer(): Promise<void> {
    await clearRebuildableProjection(this);
  }

  async applyChange(change: DeviceV3Change): Promise<void> {
    const table = projectionTable(change.resource_type);
    if (change.operation === 'tombstone') {
      await this.store.executeSql(`DELETE FROM ${table} WHERE resource_id = ?`, [change.resource_id]);
      await this.store.executeSql(
        `INSERT INTO projection_tombstones (resource_type, resource_id, revision, updated_at)
         VALUES (?, ?, ?, ?) ON CONFLICT(resource_type, resource_id) DO UPDATE SET
         revision = MAX(revision, excluded.revision), updated_at = excluded.updated_at`,
        [change.resource_type, change.resource_id, change.revision, Date.now()]);
      return;
    }
    await this.store.executeSql(
      `INSERT INTO ${table} (resource_id, revision, payload_json, updated_at)
       VALUES (?, ?, ?, ?) ON CONFLICT(resource_id) DO UPDATE SET
       revision = excluded.revision, payload_json = excluded.payload_json,
       updated_at = excluded.updated_at WHERE excluded.revision >= revision`,
      [change.resource_id, change.revision, JSON.stringify(change.resource), Date.now()]);
    await this.store.executeSql(
      'DELETE FROM projection_tombstones WHERE resource_type = ? AND resource_id = ? AND revision <= ?',
      [change.resource_type, change.resource_id, change.revision]);
  }

  async acknowledgeReceipt(receipt: DeviceV3OperationReceipt): Promise<void> {
    if (receipt.status === 'conflict') {
      await this.store.executeSql(
        `INSERT OR REPLACE INTO conflicts (operation_id, kind, payload_json, error_json, created_at)
         SELECT operation_id, kind, payload_json, ?, ? FROM outbox WHERE operation_id = ?`,
        [JSON.stringify(receipt.error), Date.now(), receipt.operation_id]);
    }
    await this.store.executeSql('DELETE FROM outbox WHERE operation_id = ?', [receipt.operation_id]);
  }

  async setCursor(cursor: string, serverTime: string): Promise<void> {
    await this.store.executeSql(
      `UPDATE sync_state SET cursor = ?, last_server_time = ?, last_error = '',
       last_attempt_at = ?, last_success_at = ?, retry_count = 0 WHERE singleton_id = 1`,
      [cursor, serverTime, Date.now(), Date.now()]);
  }

  async clearRebuildableRows(): Promise<void> {
    for (let index = 0; index < TABLES.length; index += 1) {
      await this.store.executeSql(`DELETE FROM ${TABLES[index]}`);
    }
    await this.store.executeSql('DELETE FROM projection_tombstones');
  }
}

async function migrate(store: relationalStore.RdbStore): Promise<void> {
  if (store.version > SCHEMA_VERSION) {
    throw new Error(`Phone 投影数据库版本 ${store.version} 高于当前支持版本 ${SCHEMA_VERSION}`);
  }
  if (store.version === SCHEMA_VERSION) {
    return;
  }
  store.beginTransaction();
  try {
    if (store.version < 1) {
      for (let index = 0; index < CREATE_STATEMENTS.length; index += 1) {
        await store.executeSql(CREATE_STATEMENTS[index]);
      }
      store.version = 1;
    }
    if (store.version < 2) {
      for (let index = 0; index < VERSION_2_STATEMENTS.length; index += 1) {
        await store.executeSql(VERSION_2_STATEMENTS[index]);
      }
      store.version = 2;
    }
    store.commit();
  } catch (error) {
    store.rollBack();
    throw repositoryError(error as Object);
  }
}

function repositoryError(error: Object): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(JSON.stringify(error));
}

function projectionTable(resourceType: string): string {
  switch (resourceType) {
    case 'recording_session': return 'projection_recordings';
    case 'audio_asset': return 'projection_audio_assets';
    case 'processing_run': return 'projection_processing_runs';
    case 'utterance': return 'projection_utterances';
    case 'review_item': return 'projection_review_items';
    default: throw new Error(`不支持的 V3 投影资源：${resourceType}`);
  }
}

export const PHONE_PROJECTION_SCHEMA_VERSION: number = SCHEMA_VERSION;
export const PHONE_PROJECTION_VERSION: number = V3_PROJECTION_VERSION;
