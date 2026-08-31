import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import computerTransferProtocolTest from './ComputerTransferProtocol.test';
import phoneRecordingGroupsTest from './PhoneRecordingGroups.test';
import v3ContractFixtureTest from './V3ContractFixture.test';
import phoneSyncProjectionTest from './PhoneSyncProjection.test';

export default function testsuite() {
  receivedRecordingStoreTest();
  computerTransferProtocolTest();
  phoneRecordingGroupsTest();
  v3ContractFixtureTest();
  phoneSyncProjectionTest();
}
