import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import computerTransferProtocolTest from './ComputerTransferProtocol.test';
import phoneRecordingGroupsTest from './PhoneRecordingGroups.test';
import v3ContractFixtureTest from './V3ContractFixture.test';

export default function testsuite() {
  receivedRecordingStoreTest();
  computerTransferProtocolTest();
  phoneRecordingGroupsTest();
  v3ContractFixtureTest();
}
