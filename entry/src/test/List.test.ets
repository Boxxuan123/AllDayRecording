import automaticQueueAndSyncStateTest from './AutomaticQueueAndSyncState.test';
import interruptedWavRecoveryTest from './InterruptedWavRecovery.test';
import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import sharedIoTest from './SharedIo.test';
import watchSyncProtocolTest from './WatchSyncProtocol.test';

export default function testsuite() {
  watchSyncProtocolTest();
  sharedIoTest();
  automaticQueueAndSyncStateTest();
  receivedRecordingStoreTest();
  interruptedWavRecoveryTest();
}
