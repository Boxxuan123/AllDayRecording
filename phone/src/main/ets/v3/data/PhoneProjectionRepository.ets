import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import {
  DeviceV3Change,
  DeviceV3ClientOperation,
  DeviceV3PersonChoice,
  DeviceV3OperationReceipt
} from '../../computer/ComputerTransferProtocol';
import { V3_PROJECTION_VERSION } from '../contracts/V3ContractModels';
import {
  PhonePendingOperation,
  clearRebuildableProjection
} from './PhoneSyncProjection';
import {
  PhoneV3Conflict,
  PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow,
  PhoneV3SyncStatus
} from '../domain/PhoneV3Models';
import { PhoneV3ProjectionRepositoryPort } from '../application/PhoneV3Ports';

const DATABASE_NAME: string = 'phone_v3_projection.db';
const SCHEMA_VERSION: number = 10;
const TABLES: Array<string> = [
  'projection_recordings', 'projection_audio_assets', 'projection_processing_runs',
  'projection_utterances', 'projection_review_items', 'projection_reminders'
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
  `CREATE TABLE IF NOT EXISTS projection_reminders (
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
const VERSION_3_STATEMENTS: Array<string> = [
  "ALTER TABLE local_audio_links ADD COLUMN session_id TEXT NOT NULL DEFAULT ''",
  'CREATE INDEX IF NOT EXISTS idx_local_audio_links_session_id ON local_audio_links(session_id)'
];
const VERSION_4_STATEMENTS: Array<string> = [
  "ALTER TABLE conflicts ADD COLUMN status TEXT NOT NULL DEFAULT 'conflict'"
];
const VERSION_5_STATEMENTS: Array<string> = [
  "UPDATE sync_state SET projection_version = 2, cursor = 'cursor-0' WHERE singleton_id = 1"
];
const VERSION_6_STATEMENTS: Array<string> = [
  "UPDATE sync_state SET projection_version = 3, cursor = 'cursor-0' WHERE singleton_id = 1"
];
const VERSION_7_STATEMENTS: Array<string> = [
  `CREATE TABLE IF NOT EXISTS projection_reminders (
    resource_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)`,
  "UPDATE sync_state SET projection_version = 4, cursor = 'cursor-0' WHERE singleton_id = 1"
];

export interface PhoneProjectionStatus {
  cursor: string;
  last_server_time: string;
  last_error: string;
  pending_operations: number;
  max_attempt_count: number;
  retry_count: number;
}

export class PhoneProjectionRepository implements PhoneV3ProjectionRepositoryPort {
  private store: relationalStore.RdbStore;
  private transactionTail: Promise<void> = Promise.resolve();
  private releaseTransaction: () => void = (): void => {};

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
    const previous = this.transactionTail;
    let release: () => void = (): void => {};
    this.transactionTail = new Promise<void>((resolve): void => { release = resolve; });
    await previous;
    this.releaseTransaction = release;
    try { this.store.beginTransaction(); } catch (error) { release(); throw repositoryError(error as Object); }
  }

  async commit(): Promise<void> {
    this.store.commit();
    this.releaseTransaction();
  }

  async rollback(): Promise<void> {
    try { this.store.rollBack(); } finally { this.releaseTransaction(); }
  }

  async enqueue(operation: DeviceV3ClientOperation): Promise<void> {
    await this.store.executeSql(
      `INSERT OR IGNORE INTO outbox (
        operation_id, kind, base_revision, payload_json, attempt_count, last_error, created_at)
       VALUES (?, ?, ?, ?, 0, '', ?)`,
      [operation.operation_id, operation.kind, operation.base_revision,
        JSON.stringify(operation.payload), Date.now()]);
  }

  async pendingOperations(limit: number = 500, excludedIds: Array<string> = []): Promise<Array<PhonePendingOperation>> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) {
      throw new Error('Phone outbox 查询上限无效');
    }
    const result = await this.store.querySql(
      `SELECT operation_id, kind, base_revision, payload_json, attempt_count
       FROM outbox WHERE applied_revision IS NULL OR (
         kind IN ('speaker.assign','segment.classify') AND json_array_length(payload_json,'$.selections')>1
         AND NOT EXISTS (SELECT 1 FROM outbox_resource_receipts r WHERE r.operation_id=outbox.operation_id))
       ORDER BY created_at, rowid`);
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
    const blocked = new Set<string>(operations.map((op): string => op.operation_id));
    for (let conflict of await this.conflictRows()) { blocked.add(conflict.operationId); }
    return operations.filter((op): boolean => {
      const payload = op.payload as OperationDependencies;
      return excludedIds.indexOf(op.operation_id) < 0 &&
        !(payload.depends_on ?? []).some((id: string): boolean => blocked.has(id));
    }).slice(0, limit);
  }

  async annotationOperations(): Promise<Array<PhonePendingOperation>> {
    const result = await this.store.querySql(
      "SELECT operation_id, payload_json, kind, applied_revision FROM outbox WHERE kind IN ('speaker.assign', 'segment.classify') ORDER BY created_at, rowid");
    const operations: Array<PhonePendingOperation> = [];
    try {
      while (result.goToNextRow()) {
        operations.push({ operation_id: result.getString(0), kind: result.getString(2),
          base_revision: null, payload: JSON.parse(result.getString(1)) as Object, attempt_count: 0,
          applied_revision: result.isColumnNull(3) ? undefined : result.getLong(3),
          projected_resource_ids: await this.projectedResourceIds(result.getString(0)) });
      }
    } finally { result.close(); }
    return operations;
  }

  async cachedPeople(): Promise<Array<DeviceV3PersonChoice>> {
    const result = await this.store.querySql('SELECT payload_json FROM annotation_people ORDER BY rowid');
    const people: Array<DeviceV3PersonChoice> = [];
    try {
      while (result.goToNextRow()) { people.push(JSON.parse(result.getString(0)) as DeviceV3PersonChoice); }
    } finally { result.close(); }
    return people;
  }

  async cachePeople(people: Array<DeviceV3PersonChoice>): Promise<void> {
    for (let person of people) {
      await this.store.executeSql('INSERT OR REPLACE INTO annotation_people (person_id, payload_json) VALUES (?, ?)',
        [person.person_id, JSON.stringify(person)]);
    }
  }

  async removeConflict(operationId: string): Promise<void> {
    await this.store.executeSql('DELETE FROM conflicts WHERE operation_id = ?', [operationId]);
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

  async v3Status(): Promise<PhoneV3SyncStatus> {
    const value = await this.status();
    return new PhoneV3SyncStatus(value.cursor, value.last_server_time, value.last_error,
      value.pending_operations, value.retry_count);
  }

  async projectionRows(resourceType: string): Promise<Array<PhoneV3ProjectionRow>> {
    const table = projectionTable(resourceType);
    const result = await this.store.querySql(
      `SELECT resource_id, revision, payload_json, updated_at FROM ${table}
       ORDER BY updated_at DESC, resource_id`);
    const values: Array<PhoneV3ProjectionRow> = [];
    try {
      while (result.goToNextRow()) {
        values.push(new PhoneV3ProjectionRow(
          result.getString(result.getColumnIndex('resource_id')),
          result.getLong(result.getColumnIndex('revision')),
          result.getString(result.getColumnIndex('payload_json')),
          result.getLong(result.getColumnIndex('updated_at'))));
      }
    } finally {
      result.close();
    }
    return values;
  }

  async localAudioLinks(): Promise<Array<PhoneV3LocalAudioLink>> {
    const result = await this.store.querySql(
      `SELECT session_key, session_id, local_path, upload_status, updated_at
       FROM local_audio_links ORDER BY updated_at DESC, local_path`);
    const values: Array<PhoneV3LocalAudioLink> = [];
    try {
      while (result.goToNextRow()) {
        values.push(new PhoneV3LocalAudioLink(
          result.getString(result.getColumnIndex('session_key')),
          result.getString(result.getColumnIndex('session_id')),
          result.getString(result.getColumnIndex('local_path')),
          result.getString(result.getColumnIndex('upload_status')),
          result.getLong(result.getColumnIndex('updated_at'))));
      }
    } finally {
      result.close();
    }
    return values;
  }

  async conflictRows(): Promise<Array<PhoneV3Conflict>> {
    const result = await this.store.querySql(
      `SELECT operation_id, kind, status, error_json, created_at, payload_json FROM conflicts
       ORDER BY created_at DESC, operation_id`);
    const values: Array<PhoneV3Conflict> = [];
    try {
      while (result.goToNextRow()) {
        values.push(new PhoneV3Conflict(
          result.getString(result.getColumnIndex('operation_id')),
          result.getString(result.getColumnIndex('kind')),
          result.getString(result.getColumnIndex('status')),
          result.getString(result.getColumnIndex('error_json')),
          result.getLong(result.getColumnIndex('created_at')),
          result.getString(result.getColumnIndex('payload_json'))));
      }
    } finally {
      result.close();
    }
    return values;
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

  async replaceReviewItems(items: Array<Object>): Promise<void> {
    await this.beginTransaction();
    try {
      await this.store.executeSql('DELETE FROM projection_review_items');
      for (let index = 0; index < items.length; index += 1) {
        const item = items[index] as ReviewSnapshotPayload;
        if (typeof item.review_id !== 'string' || item.review_id.length === 0) {
          throw new Error('电脑返回的审核快照包含无效 ID');
        }
        const revision = typeof item.source_revision === 'number' && item.source_revision > 0 ?
          item.source_revision : 1;
        const parsedTime = typeof item.updated_at === 'string' ? Date.parse(item.updated_at) : Date.now();
        await this.store.executeSql(
          `INSERT INTO projection_review_items (resource_id, revision, payload_json, updated_at)
           VALUES (?, ?, ?, ?)`,
          [item.review_id, revision, JSON.stringify(item),
            Number.isFinite(parsedTime) ? parsedTime : Date.now()]);
      }
      await this.commit();
    } catch (error) {
      await this.rollback();
      throw repositoryError(error as Object);
    }
  }

  async markSyncFailure(message: string): Promise<void> {
    const text = message.substring(0, 1000);
    await this.beginTransaction();
    try {
      await this.store.executeSql(
        'UPDATE outbox SET attempt_count = attempt_count + 1, last_error = ?', [text]);
      await this.store.executeSql(
        `UPDATE sync_state SET last_error = ?, last_attempt_at = ?,
         retry_count = retry_count + 1 WHERE singleton_id = 1`,
        [text, Date.now()]);
      await this.commit();
    } catch (error) {
      await this.rollback();
      throw repositoryError(error as Object);
    }
  }

  async rebuildFromComputer(): Promise<void> {
    await clearRebuildableProjection(this);
  }

  async applyChange(change: DeviceV3Change): Promise<void> {
    const table = projectionTable(change.resource_type);
    if (change.operation === 'tombstone') {
      if (change.resource_type === 'recording_session') {
        await this.rebindCanonicalSession(change.resource_id, change.resource);
      }
      await this.store.executeSql(`DELETE FROM ${table} WHERE resource_id = ?`, [change.resource_id]);
      await this.store.executeSql(
        `INSERT INTO projection_tombstones (resource_type, resource_id, revision, updated_at)
         VALUES (?, ?, ?, ?) ON CONFLICT(resource_type, resource_id) DO UPDATE SET
         revision = MAX(revision, excluded.revision), updated_at = excluded.updated_at`,
        [change.resource_type, change.resource_id, change.revision, Date.now()]);
      return;
    }
    const resource = change.resource_type === 'recording_session' ?
      await this.preserveRecordingSessionKey(change.resource_id, change.resource) : change.resource;
    await this.store.executeSql(
      `INSERT INTO ${table} (resource_id, revision, payload_json, updated_at)
       VALUES (?, ?, ?, ?) ON CONFLICT(resource_id) DO UPDATE SET
       revision = excluded.revision, payload_json = excluded.payload_json,
       updated_at = excluded.updated_at WHERE excluded.revision >= revision`,
      [change.resource_id, change.revision, JSON.stringify(resource), Date.now()]);
    if (change.resource_type === 'recording_session') {
      await this.bindLocalSession(change.resource_id, resource as Object);
    }
    await this.store.executeSql(
      'DELETE FROM projection_tombstones WHERE resource_type = ? AND resource_id = ? AND revision <= ?',
      [change.resource_type, change.resource_id, change.revision]);
  }

  async acknowledgeReceipt(receipt: DeviceV3OperationReceipt): Promise<void> {
    if (receipt.status === 'conflict' || receipt.status === 'rejected') {
      await this.store.executeSql(
        `INSERT OR REPLACE INTO conflicts (
           operation_id, kind, payload_json, error_json, created_at, status)
         SELECT operation_id, kind, payload_json, ?, ?, ? FROM outbox WHERE operation_id = ?`,
        [JSON.stringify(receipt.error), Date.now(), receipt.status, receipt.operation_id]);
    }
    if (receipt.status === 'applied') {
      // Retain the only local identity overlay until its authoritative row arrives,
      // possibly on a later pull page. Applied rows are never sent again.
      await this.store.executeSql('UPDATE outbox SET applied_revision = ? WHERE operation_id = ?',
        [receipt.resource_revision, receipt.operation_id]);
      const pending = await this.store.querySql('SELECT payload_json FROM outbox WHERE operation_id=?', [receipt.operation_id]);
      try {
        if (pending.goToNextRow()) {
          const payload = JSON.parse(pending.getString(0)) as OperationDependencies;
          const selections = payload.selections ?? [];
          if (receipt.resource_results !== undefined && (receipt.resource_results.length !== selections.length ||
            selections.some((s): boolean => !receipt.resource_results!.some((r): boolean => r.resource_id === s.utterance_id)))) {
            throw new Error('逐资源回执与原操作不一致');
          }
          for (let selection of selections) {
            const target = receipt.resource_results?.find((r): boolean => r.resource_id === selection.utterance_id);
            const revision = target?.revision ?? (selections.length === 1 ? receipt.resource_revision : null);
            if (revision !== null) {
              await this.store.executeSql('INSERT OR IGNORE INTO outbox_resource_receipts VALUES(?,?,?,0)',
                [receipt.operation_id, selection.utterance_id, revision]);
            }
          }
        }
      } finally { pending.close(); }
      await this.clearProjectedOperations();
    } else {
      await this.store.executeSql('DELETE FROM outbox WHERE operation_id = ?', [receipt.operation_id]);
    }
  }

  private async projectedResourceIds(operationId: string): Promise<Array<string>> {
    const result = await this.store.querySql('SELECT resource_id FROM outbox_resource_receipts WHERE operation_id=? AND projected=1', [operationId]);
    const ids: Array<string> = [];
    try { while (result.goToNextRow()) { ids.push(result.getString(0)); } }
    finally { result.close(); }
    return ids;
  }

  private async clearProjectedOperations(): Promise<void> {
    await this.store.executeSql(`UPDATE outbox_resource_receipts SET projected=1 WHERE EXISTS (
      SELECT 1 FROM projection_utterances p WHERE p.resource_id=outbox_resource_receipts.resource_id AND p.revision>=outbox_resource_receipts.target_revision)
      OR EXISTS (SELECT 1 FROM projection_tombstones t WHERE t.resource_type='utterance'
        AND t.resource_id=outbox_resource_receipts.resource_id AND t.revision>=outbox_resource_receipts.target_revision)`);
    const result = await this.store.querySql('SELECT operation_id, payload_json FROM outbox WHERE applied_revision IS NOT NULL');
    const completed: Array<string> = [];
    try {
      while (result.goToNextRow()) {
        const payload = JSON.parse(result.getString(1)) as OperationDependencies;
        const projected = await this.projectedResourceIds(result.getString(0));
        if ((payload.selections ?? []).every((s): boolean => projected.indexOf(s.utterance_id) >= 0)) {
          completed.push(result.getString(0));
        }
      }
    } finally { result.close(); }
    for (let id of completed) { await this.store.executeSql('DELETE FROM outbox WHERE operation_id = ?', [id]); }
    await this.store.executeSql('DELETE FROM outbox_resource_receipts WHERE operation_id NOT IN (SELECT operation_id FROM outbox)');
  }

  async setCursor(cursor: string, serverTime: string): Promise<void> {
    await this.clearProjectedOperations();
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

  private async bindLocalSession(sessionId: string, resource: Object): Promise<void> {
    const payload = resource as RecordingSessionLinkPayload;
    if (typeof payload.session_key !== 'string' || payload.session_key.length === 0) {
      return;
    }
    await this.store.executeSql(
      'UPDATE local_audio_links SET session_id = ?, updated_at = ? WHERE session_key = ?',
      [sessionId, Date.now(), payload.session_key]);
  }

  private async rebindCanonicalSession(sessionId: string, resource: Object | null): Promise<void> {
    const payload = resource as RecordingSessionTombstonePayload | null;
    if (payload === null || typeof payload.canonical_session_id !== 'string' ||
      payload.canonical_session_id.length === 0 || payload.canonical_session_id === sessionId) {
      return;
    }
    await this.store.executeSql(
      'UPDATE local_audio_links SET session_id = ?, updated_at = ? WHERE session_id = ?',
      [payload.canonical_session_id, Date.now(), sessionId]);
  }

  private async preserveRecordingSessionKey(resourceId: string, resource: Object | null): Promise<Object | null> {
    if (resource === null) {
      return null;
    }
    const incoming = resource as RecordingSessionLinkPayload;
    if (typeof incoming.session_key === 'string' && incoming.session_key.length > 0) {
      return resource;
    }
    const result = await this.store.querySql(
      'SELECT payload_json FROM projection_recordings WHERE resource_id = ?', [resourceId]);
    try {
      if (!result.goToNextRow()) {
        return resource;
      }
      const previous = JSON.parse(result.getString(result.getColumnIndex('payload_json'))) as RecordingSessionLinkPayload;
      if (typeof previous.session_key !== 'string' || previous.session_key.length === 0) {
        return resource;
      }
      incoming.session_key = previous.session_key;
      return incoming as Object;
    } finally {
      result.close();
    }
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
    if (store.version < 3) {
      for (let index = 0; index < VERSION_3_STATEMENTS.length; index += 1) {
        await store.executeSql(VERSION_3_STATEMENTS[index]);
      }
      store.version = 3;
    }
    if (store.version < 4) {
      for (let index = 0; index < VERSION_4_STATEMENTS.length; index += 1) {
        await store.executeSql(VERSION_4_STATEMENTS[index]);
      }
      store.version = 4;
    }
    if (store.version < 5) {
      for (let index = 0; index < VERSION_5_STATEMENTS.length; index += 1) {
        await store.executeSql(VERSION_5_STATEMENTS[index]);
      }
      store.version = 5;
    }
    if (store.version < 6) {
      for (let index = 0; index < VERSION_6_STATEMENTS.length; index += 1) {
        await store.executeSql(VERSION_6_STATEMENTS[index]);
      }
      store.version = 6;
    }
    if (store.version < 7) {
      for (let index = 0; index < VERSION_7_STATEMENTS.length; index += 1) {
        await store.executeSql(VERSION_7_STATEMENTS[index]);
      }
      store.version = 7;
    }
    if (store.version < 8) {
      await store.executeSql('CREATE TABLE IF NOT EXISTS annotation_people (person_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL)');
      store.version = 8;
    }
    if (store.version < 9) {
      await store.executeSql('ALTER TABLE outbox ADD COLUMN applied_revision INTEGER');
      store.version = 9;
    }
    if (store.version < 10) {
      await store.executeSql(`CREATE TABLE IF NOT EXISTS outbox_resource_receipts (
        operation_id TEXT NOT NULL, resource_id TEXT NOT NULL, target_revision INTEGER NOT NULL,
        projected INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(operation_id,resource_id))`);
      await store.executeSql(`INSERT OR IGNORE INTO outbox_resource_receipts
        SELECT o.operation_id,json_extract(j.value,'$.utterance_id'),o.applied_revision,0
        FROM outbox o,json_each(o.payload_json,'$.selections') j
        WHERE o.applied_revision IS NOT NULL AND json_array_length(o.payload_json,'$.selections')=1`);
      store.version = 10;
    }
    store.commit();
  } catch (error) {
    store.rollBack();
    throw repositoryError(error as Object);
  }
}

interface OperationSelection { utterance_id: string; }
interface OperationDependencies {
  depends_on?: Array<string>;
  selections?: Array<OperationSelection>;
}

interface RecordingSessionLinkPayload {
  session_key?: string;
}

interface ReviewSnapshotPayload {
  review_id?: string;
  source_revision?: number | null;
  updated_at?: string;
}

interface RecordingSessionTombstonePayload {
  canonical_session_id?: string;
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
    case 'reminder': return 'projection_reminders';
    default: throw new Error(`不支持的 V3 投影资源：${resourceType}`);
  }
}

export const PHONE_PROJECTION_SCHEMA_VERSION: number = SCHEMA_VERSION;
export const PHONE_PROJECTION_VERSION: number = V3_PROJECTION_VERSION;
