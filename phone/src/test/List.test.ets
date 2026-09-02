import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import computerTransferProtocolTest from './ComputerTransferProtocol.test';
import phoneV3LocalAudioGroupsTest from './PhoneV3LocalAudioGroups.test';
import v3ContractFixtureTest from './V3ContractFixture.test';
import phoneSyncProjectionTest from './PhoneSyncProjection.test';
import phoneV3UseCasesTest from './PhoneV3UseCases.test';
import computerSessionManifestTest from './ComputerSessionManifest.test';
import computerRecordingBackupServiceTest from './ComputerRecordingBackupService.test';

export default function testsuite() {
  receivedRecordingStoreTest();
  computerTransferProtocolTest();
  phoneV3LocalAudioGroupsTest();
  v3ContractFixtureTest();
  phoneSyncProjectionTest();
  phoneV3UseCasesTest();
  computerSessionManifestTest();
  computerRecordingBackupServiceTest();
}
