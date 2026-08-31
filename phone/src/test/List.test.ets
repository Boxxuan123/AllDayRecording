import receivedRecordingStoreTest from './ReceivedRecordingStore.test';
import computerTransferProtocolTest from './ComputerTransferProtocol.test';
import phoneRecordingGroupsTest from './PhoneRecordingGroups.test';

export default function testsuite() {
  receivedRecordingStoreTest();
  computerTransferProtocolTest();
  phoneRecordingGroupsTest();
}
