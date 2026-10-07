/** Shared write boundary owned by PhoneProjectionRepository. */
export interface PhoneProjectionTransaction {
  beginTransaction(): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}
