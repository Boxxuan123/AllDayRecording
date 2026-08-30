import automaticQueueAndSyncStateTest from './AutomaticQueueAndSyncState.test';
import interruptedWavRecoveryTest from './InterruptedWavRecovery.test';
import pcmRecordingDomainTest from './PcmRecordingDomain.test';
import presentationStateTest from './PresentationState.test';
import sharedIoTest from './SharedIo.test';
import watchSyncProtocolTest from './WatchSyncProtocol.test';

export default function testsuite() {
  watchSyncProtocolTest();
  sharedIoTest();
  automaticQueueAndSyncStateTest();
  presentationStateTest();
  interruptedWavRecoveryTest();
  pcmRecordingDomainTest();
}
