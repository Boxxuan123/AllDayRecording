import automaticQueueAndSyncStateTest from './AutomaticQueueAndSyncState.test';
import interruptedWavRecoveryTest from './InterruptedWavRecovery.test';
import pcmRecordingDomainTest from './PcmRecordingDomain.test';
import presentationStateTest from './PresentationState.test';
import sharedIoTest from './SharedIo.test';
import watchSyncProtocolTest from './WatchSyncProtocol.test';
import wifiRecordingTransferPolicyTest from './WifiRecordingTransferPolicy.test';
import wifiSyncedSourceCleanerTest from './WifiSyncedSourceCleaner.test';

export default function testsuite() {
  watchSyncProtocolTest();
  sharedIoTest();
  automaticQueueAndSyncStateTest();
  presentationStateTest();
  interruptedWavRecoveryTest();
  pcmRecordingDomainTest();
  wifiRecordingTransferPolicyTest();
  wifiSyncedSourceCleanerTest();
}
