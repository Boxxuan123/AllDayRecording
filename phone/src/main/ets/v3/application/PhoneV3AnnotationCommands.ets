import { annotationTiming } from './PhoneAnnotationTiming';
import { DeviceV3ClientOperation, DeviceV3PersonChoice } from '../../computer/ComputerTransferProtocol';
import { PhonePendingOperation } from '../data/PhoneSyncProjection';
import { PHONE_V3_SOUND_KINDS, phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { PhoneV3LocalAnnotation, PhoneV3AnnotationSentence } from '../domain/PhoneV3LocalAnnotation';
import { PhoneV3ProjectionRow, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ProjectionRepositoryPort } from './PhoneV3Ports';
import { newOperationId } from './PhoneV3OperationIds';

interface AnnotationTargetPayload { status: string; }
interface UtteranceCorrectionPayload {
  utterance_id: string;
  text: string;
  speaker_track_id: string | null;
  identity: string;
}

/** Local annotation and transcript commands; every multi-row command commits atomically. */
export class PhoneV3AnnotationCommands {
  private repository: PhoneV3ProjectionRepositoryPort;
  constructor(repository: PhoneV3ProjectionRepositoryPort) { this.repository = repository; }

  async queueUtteranceCorrection(utterance: PhoneV3Utterance,
    textValue: string, speakerTrackId: string | null, identity: string): Promise<void> {
    const text = textValue.trim();
    if (text.length === 0) {
      throw new Error('utterance 校正文本不能为空');
    }
    if (['self', 'not_self', 'unknown'].indexOf(identity) < 0) {
      throw new Error('utterance 本人身份无效');
    }
    if (text === utterance.text && speakerTrackId === utterance.speakerTrackId &&
      identity === utterance.identity) {
      throw new Error('utterance 校正没有产生变化');
    }
    const payload: UtteranceCorrectionPayload = {
      utterance_id: utterance.utteranceId,
      text: text,
      speaker_track_id: speakerTrackId,
      identity: identity
    };
    const operation: DeviceV3ClientOperation = {
      operation_id: newOperationId(),
      kind: 'utterance.correct',
      base_revision: utterance.revision,
      payload: payload
    };
    await this.repository.beginTransaction();
    try { await this.repository.enqueue(operation); await this.repository.commit(); }
    catch (error) { await this.repository.rollback(); throw error as Error; }
  }

  async queueSpeakerAnnotation(utterances: Array<PhoneV3Utterance>, personId: string,
    name: string): Promise<void> {
    await this.queueAnnotation(utterances, personId, name, true, '');
  }

  async queueSoundClassification(utterances: Array<PhoneV3Utterance>, soundKind: string): Promise<void> {
    await this.queueAnnotation(utterances, '', '', false, soundKind);
  }

  // One transaction for both dimensions. Helpers below never start nested transactions.
  async queueAnnotation(utterances: Array<PhoneV3Utterance>, personId: string, name: string,
    personChanged: boolean, soundKind: string): Promise<Array<PhonePendingOperation>> {
    if (utterances.length === 0 || utterances.length > 2000 ||
      (!personChanged && soundKind.length === 0) ||
      (soundKind.length > 0 && PHONE_V3_SOUND_KINDS.indexOf(soundKind) < 0)) {
      throw new Error('请选择 1 至 2000 个片段，并选择人物或声音类型');
    }
    const ids = new Set<string>(utterances.map((row: PhoneV3Utterance): string => row.utteranceId));
    if (ids.size !== utterances.length || utterances.some((row: PhoneV3Utterance): boolean => row.status !== 'active')) {
      throw new Error('选择包含重复或失效片段，请重新核对');
    }
    const selections = utterances.map((value: PhoneV3Utterance): PhoneV3AnnotationSentence => {
      return { utterance_id: value.utteranceId, revision: value.revision, text: value.text,
        speaker_label: value.speakerLabel ?? '未知说话人', sound_kind: value.soundKind,
        session_id: value.sessionId, start_ms: value.startMs, end_ms: value.endMs };
    });
    const committed: Array<PhonePendingOperation> = [];
    await this.repository.beginTransaction();
    try {
      const projections = await this.repository.projectionRows('utterance', Array.from(ids));
      const current = new Map<string, PhoneV3ProjectionRow>();
      for (let projection of projections) { if (ids.has(projection.resourceId)) { current.set(projection.resourceId, projection); } }
      for (let reviewed of utterances) {
        const projection = current.get(reviewed.utteranceId);
        if (projection === undefined || projection.revision !== reviewed.revision ||
          (JSON.parse(projection.payloadJson) as AnnotationTargetPayload).status !== 'active') {
          throw new Error('片段已变化或不存在，请重新打开核对后保存');
        }
      }
      if (personChanged) {
        const people = personId.length > 0 ? await this.repository.cachedPeople(personId) : [];
        const person = people.find((value: DeviceV3PersonChoice): boolean => value.person_id === personId);
        if (personId.length > 0 && person === undefined) { throw new Error('请重新选择人物'); }
        const label = person === undefined ? name.trim() : person.display_name;
        if (label.length === 0 || label.length > 100) { throw new Error('人物姓名应为 1 至 100 字'); }
        const choice: DeviceV3PersonChoice = person ?? { person_id: newOperationId(), display_name: label, local: true };
        const payload: PhoneV3LocalAnnotation = { selections: selections, person_name: label };
        if (choice.local) { payload.new_person_id = choice.person_id; payload.display_name = label; }
        else { payload.person_id = choice.person_id; }
        await this.repository.cachePeople([choice]);
        committed.push(...await this.enqueueAnnotationItems('speaker.assign', payload));
      }
      if (soundKind.length > 0) {
        committed.push(...await this.enqueueAnnotationItems('segment.classify', { selections: selections,
          person_name: phoneV3SoundKindLabel(soundKind), sound_kind: soundKind }));
      }
      await this.repository.commit();
      annotationTiming('T0-local-commit', committed.map((op): string => op.operation_id));
      return committed;
    } catch (error) {
      await this.repository.rollback();
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
  }

  private async enqueueAnnotationItems(kind: string, payload: PhoneV3LocalAnnotation): Promise<Array<PhonePendingOperation>> {
    const predecessors = await this.repository.annotationOperations(payload.selections.map((row): string => row.utterance_id));
    const committed: Array<PhonePendingOperation> = [];
    for (let selection of payload.selections) {
      const dependencies: Array<string> = [];
      for (let operation of predecessors) {
        if (operation.kind !== kind) { continue; }
        const previous = operation.payload as PhoneV3LocalAnnotation;
        if (previous.selections.some((row: PhoneV3AnnotationSentence): boolean =>
          row.utterance_id === selection.utterance_id)) { dependencies.push(operation.operation_id); }
      }
      const item: PhoneV3LocalAnnotation = { selections: [selection], person_name: payload.person_name,
        person_id: payload.person_id, new_person_id: payload.new_person_id,
        display_name: payload.display_name, sound_kind: payload.sound_kind, depends_on: dependencies };
      const operation: PhonePendingOperation = { operation_id: newOperationId(), kind: kind,
        base_revision: null, payload: item, attempt_count: 0 };
      await this.repository.enqueue(operation);
      committed.push(operation);
    }
    return committed;
  }

}
