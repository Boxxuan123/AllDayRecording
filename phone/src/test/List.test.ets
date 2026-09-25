import annotationIndexTest from './PhoneV3AnnotationIndex.test';
import computerUploadQueueTest from './ComputerUploadQueue.test';
import phoneV3RecordingStoreTest from './PhoneV3RecordingStore.test';
import computerTransferProtocolTest from './ComputerTransferProtocol.test';
import phoneV3LocalAudioGroupsTest from './PhoneV3LocalAudioGroups.test';
import v3ContractFixtureTest from './V3ContractFixture.test';
import phoneSyncProjectionTest from './PhoneSyncProjection.test';
import phoneV3UseCasesTest from './PhoneV3UseCases.test';
import computerSessionManifestTest from './ComputerSessionManifest.test';
import computerRecordingBackupServiceTest from './ComputerRecordingBackupService.test';
import phoneV3ComputerBackupTest from './PhoneV3ComputerBackup.test';
import phoneV3ReviewModelsTest from './PhoneV3ReviewModels.test';

export default function testsuite() {
  annotationIndexTest();
  computerUploadQueueTest();
  phoneV3RecordingStoreTest();
  computerTransferProtocolTest();
  phoneV3LocalAudioGroupsTest();
  v3ContractFixtureTest();
  phoneSyncProjectionTest();
  phoneV3UseCasesTest();
  computerSessionManifestTest();
  computerRecordingBackupServiceTest();
  phoneV3ComputerBackupTest();
  phoneV3ReviewModelsTest();
}
