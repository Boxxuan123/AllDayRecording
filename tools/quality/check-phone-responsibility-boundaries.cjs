const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Repository } = require('./phone-sqlite-harness.cjs');
const { voiceReviewCommand, purityReviewCommand } = require(
  '../../phone/src/main/ets/v3/application/PhoneV3ReviewCommands.ets');

(async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'phone-boundary-'));
  const repository = await Repository.open({ databasePath: path.join(directory, 'fixture.db') });
  assert.deepEqual(await repository.projectionRows('utterance'), []);
  const mapping = { taskId: 'task-1', calendarAccountId: 1, calendarEventId: -1,
    scheduledDueAt: '', scheduledTitle: '', calendarSyncState: 'creating', lastError: '' };
  await repository.saveCalendarMapping(mapping);
  assert.equal((await repository.calendarMappings())[0].taskId, 'task-1');
  const review = { operation_id: 'operation-1', review_id: 'review-1',
    prototype_id: 'prototype-1', action: 'confirm' };
  await repository.enqueueVoiceReview(review);
  assert.equal((await repository.pendingVoiceReviews()).length, 1);
  await repository.removeVoiceReview(review.operation_id);
  assert.equal((await repository.pendingVoiceReviews()).length, 0);

  const snapshot = { reviewItems: [], sessions: [] };
  assert.equal(voiceReviewCommand('review-1', 'confirm', 'prototype-1', '', snapshot, false), undefined);
  assert.equal(voiceReviewCommand('review-1', 'confirm', 'prototype-1', '', snapshot, true).prototype_id,
    'prototype-1');
  assert.equal(purityReviewCommand('blind:1', 'person-1', true, 'uncertain', [], [], false,
    'dont_know', 2, 'mixed', 'cross').review_schema_version, 2);
  console.log('Phone responsibility boundaries PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
