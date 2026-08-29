import automaticQueueAndSyncStateTest from './AutomaticQueueAndSyncState.test';
import interruptedWavRecoveryTest from './InterruptedWavRecovery.test';
import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import watchSyncProtocolTest from './WatchSyncProtocol.test';

export default function testsuite() {
  watchSyncProtocolTest();
  automaticQueueAndSyncStateTest();
  receivedRecordingStoreTest();
  interruptedWavRecoveryTest();
}
