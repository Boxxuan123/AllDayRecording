import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import computerTransferProtocolTest from './ComputerTransferProtocol.test';
import phoneRecordingGroupsTest from './PhoneRecordingGroups.test';
import v3ContractFixtureTest from './V3ContractFixture.test';
import phoneSyncProjectionTest from './PhoneSyncProjection.test';
import phoneV3UseCasesTest from './PhoneV3UseCases.test';
import computerSessionManifestTest from './ComputerSessionManifest.test';
import computerRecordingBackupServiceTest from './ComputerRecordingBackupService.test';

export default function testsuite() {
  receivedRecordingStoreTest();
  computerTransferProtocolTest();
  phoneRecordingGroupsTest();
  v3ContractFixtureTest();
  phoneSyncProjectionTest();
  phoneV3UseCasesTest();
  computerSessionManifestTest();
  computerRecordingBackupServiceTest();
}
