import { relationalStore } from '@kit.ArkData';
import { PhoneV3ProjectionRow } from '../domain/PhoneV3Models';

/** Read-only SQL for cached projections and cursor-paged transcript queries. */
export class PhoneProjectionQueriesStore {
  private store: relationalStore.RdbStore;
  constructor(store: relationalStore.RdbStore) { this.store = store; }

  async projectionRows(resourceType: string, resourceIds?: Array<string>): Promise<Array<PhoneV3ProjectionRow>> {
    if (resourceIds !== undefined && resourceIds.length === 0) { return []; }
    if (resourceIds !== undefined && resourceIds.length > 400) {
      let rows: Array<PhoneV3ProjectionRow> = [];
      for (let offset = 0; offset < resourceIds.length; offset += 400) {
        rows = rows.concat(await this.projectionRows(resourceType, resourceIds.slice(offset, offset + 400)));
      }
      return rows;
    }
    const table = projectionTable(resourceType);
    const filter = resourceIds === undefined ? '' : ` WHERE resource_id IN (${resourceIds.map((): string => '?').join(',')})`;
    const result = await this.store.querySql(
      `SELECT resource_id, revision, payload_json, updated_at FROM ${table}${filter}
       ORDER BY updated_at DESC, resource_id`, resourceIds ?? []);
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

  async sessionUtteranceRows(sessionId: string, limit: number = 50,
    afterStartMs: number = -1, afterId: string = ''): Promise<Array<PhoneV3ProjectionRow>> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) {
      throw new Error('Phone 会话转写查询上限无效');
    }
    const result = await this.store.querySql(
      `SELECT resource_id, revision, payload_json, updated_at FROM projection_utterances
       WHERE session_id = ? AND status = 'active'
         AND (start_ms > ? OR (start_ms = ? AND resource_id > ?))
       ORDER BY start_ms, resource_id LIMIT ?`,
      [sessionId, afterStartMs, afterStartMs, afterId, limit]);
    const rows: Array<PhoneV3ProjectionRow> = [];
    try {
      while (result.goToNextRow()) {
        rows.push(new PhoneV3ProjectionRow(
          result.getString(result.getColumnIndex('resource_id')),
          result.getLong(result.getColumnIndex('revision')),
          result.getString(result.getColumnIndex('payload_json')),
          result.getLong(result.getColumnIndex('updated_at'))));
      }
    } finally { result.close(); }
    return rows;
  }

  async sessionUtteranceCount(sessionId: string): Promise<number> {
    const result = await this.store.querySql(
      `SELECT COUNT(*) FROM projection_utterances WHERE session_id = ? AND status = 'active'`, [sessionId]);
    try { return result.goToNextRow() ? result.getLong(0) : 0; }
    finally { result.close(); }
  }

  async sessionUtteranceCounts(): Promise<Map<string, number>> {
    const result = await this.store.querySql(
      `SELECT session_id, COUNT(*) AS total FROM projection_utterances
       WHERE status = 'active' GROUP BY session_id`);
    const counts: Map<string, number> = new Map<string, number>();
    try {
      while (result.goToNextRow()) {
        counts.set(result.getString(0), result.getLong(1));
      }
    } finally { result.close(); }
    return counts;
  }

  async projectionUtterancesBySession(): Promise<Map<string, Array<PhoneV3ProjectionRow>>> {
    const result = await this.store.querySql(
      `SELECT session_id, resource_id, revision, payload_json, updated_at
       FROM projection_utterances ORDER BY session_id, start_ms, resource_id`);
    const grouped = new Map<string, Array<PhoneV3ProjectionRow>>();
    try {
      while (result.goToNextRow()) {
        const sessionId = result.getString(result.getColumnIndex('session_id'));
        const values = grouped.get(sessionId) ?? [];
        values.push(new PhoneV3ProjectionRow(
          result.getString(result.getColumnIndex('resource_id')),
          result.getLong(result.getColumnIndex('revision')),
          result.getString(result.getColumnIndex('payload_json')),
          result.getLong(result.getColumnIndex('updated_at'))));
        grouped.set(sessionId, values);
      }
    } finally { result.close(); }
    return grouped;
  }

  async searchTranscriptSessionIds(search: string): Promise<Array<string>> {
    const escaped = search.trim().replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_');
    if (escaped.length === 0) { return []; }
    const pattern = `%${escaped}%`;
    const result = await this.store.querySql(
      `SELECT DISTINCT session_id FROM projection_utterances
       WHERE json_extract(payload_json, '$.text') LIKE ? ESCAPE '\\'
          OR json_extract(payload_json, '$.speaker_label') LIKE ? ESCAPE '\\'`,
      [pattern, pattern]);
    const ids: Array<string> = [];
    try { while (result.goToNextRow()) { ids.push(result.getString(0)); } }
    finally { result.close(); }
    return ids;
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
}

export function projectionTable(resourceType: string): string {
  switch (resourceType) {
    case 'recording_session': return 'projection_recordings';
    case 'audio_asset': return 'projection_audio_assets';
    case 'processing_run': return 'projection_processing_runs';
    case 'utterance': return 'projection_utterances';
    case 'review_item': return 'projection_review_items';
    case 'reminder': return 'projection_reminders';
    case 'daily_event': return 'projection_daily_events';
    case 'daily_summary': return 'projection_daily_summaries';
    default: throw new Error(`不支持的 V3 投影资源：${resourceType}`);
  }
}
