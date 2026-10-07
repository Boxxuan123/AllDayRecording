import { relationalStore } from '@kit.ArkData';
import { DeviceV3ReviewActionRequest } from '../../computer/ComputerTransferProtocol';
import { PhoneProjectionTransaction } from './PhoneProjectionTransaction';

/** Durable offline review outbox with one shared write boundary. */
export class PhoneReviewQueueStore {
  private store: relationalStore.RdbStore;
  private transactions: PhoneProjectionTransaction;
  constructor(store: relationalStore.RdbStore, transactions: PhoneProjectionTransaction) {
    this.store = store; this.transactions = transactions;
  }

  async enqueuePurityReview(request: DeviceV3ReviewActionRequest): Promise<void> {
    if (!request.operation_id) { throw new Error('缺少本机审核编号'); }
    await this.transactions.beginTransaction();
    try {
      await this.store.executeSql(
        'INSERT INTO pending_purity_reviews(operation_id, review_id, payload_json, created_at) VALUES(?,?,?,?)',
        [request.operation_id, request.review_id, JSON.stringify(request), Date.now()]);
      await this.transactions.commit();
    } catch (error) { await this.transactions.rollback(); throw error as Error; }
  }

  async pendingPurityReviews(): Promise<Array<DeviceV3ReviewActionRequest>> {
    const result = await this.store.querySql(
      'SELECT payload_json FROM pending_purity_reviews ORDER BY created_at, rowid');
    const values: Array<DeviceV3ReviewActionRequest> = [];
    try {
      while (result.goToNextRow()) {
        values.push(JSON.parse(result.getString(result.getColumnIndex('payload_json'))) as DeviceV3ReviewActionRequest);
      }
    } finally { result.close(); }
    return values;
  }

  async removePurityReview(operationId: string): Promise<void> {
    await this.transactions.beginTransaction();
    try {
      await this.store.executeSql('DELETE FROM pending_purity_reviews WHERE operation_id=?', [operationId]);
      await this.transactions.commit();
    } catch (error) { await this.transactions.rollback(); throw error as Error; }
  }

  async enqueueVoiceReview(request: DeviceV3ReviewActionRequest): Promise<void> {
    if (!request.operation_id || !request.prototype_id) { throw new Error('缺少本机声音审核编号'); }
    await this.transactions.beginTransaction();
    try {
      await this.store.executeSql(
        'INSERT INTO pending_voice_reviews(operation_id, review_id, prototype_id, payload_json, created_at) VALUES(?,?,?,?,?)',
        [request.operation_id, request.review_id, request.prototype_id, JSON.stringify(request), Date.now()]);
      await this.transactions.commit();
    } catch (error) { await this.transactions.rollback(); throw error as Error; }
  }

  async pendingVoiceReviews(): Promise<Array<DeviceV3ReviewActionRequest>> {
    const result = await this.store.querySql('SELECT payload_json FROM pending_voice_reviews ORDER BY created_at, rowid');
    const values: Array<DeviceV3ReviewActionRequest> = [];
    try {
      while (result.goToNextRow()) {
        values.push(JSON.parse(result.getString(result.getColumnIndex('payload_json'))) as DeviceV3ReviewActionRequest);
      }
    } finally { result.close(); }
    return values;
  }

  async removeVoiceReview(operationId: string): Promise<void> {
    await this.transactions.beginTransaction();
    try {
      await this.store.executeSql('DELETE FROM pending_voice_reviews WHERE operation_id=?', [operationId]);
      await this.transactions.commit();
    } catch (error) { await this.transactions.rollback(); throw error as Error; }
  }
}
