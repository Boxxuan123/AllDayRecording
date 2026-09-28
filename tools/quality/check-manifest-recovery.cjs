// Exercise durable file, manifest-version and failure receipts with real SQLite.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const {Repository} = require('./phone-sqlite-harness.cjs');

(async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'manifest-recovery-'));
  const databasePath = path.join(directory, 'phone.db');
  const first = await Repository.open({databasePath});
  const sessionKey = 'watch-session:1767225600000';
  await first.linkLocalAudio(sessionKey, '/phone/segment.wav', 'a'.repeat(64), 'uploaded');
  await first.recordSessionCompletion({sessionKey, source:'watch_stop', completedSegments:2,
    totalSamples:32000, confirmedAt:1767225601000, manifestSha256:'b'.repeat(64), inputRevision:2});
  await first.recordSessionFailure({sessionKey, manifestSha256:'c'.repeat(64),
    category:'conflict', reason:'旧分片哈希改变', attemptCount:3, retryAt:0, updatedAt:12345});
  const restarted = await Repository.open({databasePath});
  const links = await restarted.localAudioLinks();
  const versions = await restarted.localSessionCompletions();
  const failures = await restarted.localSessionFailures();
  assert.equal(links.length,1);assert.equal(links[0].sha256,'a'.repeat(64));
  assert.equal(versions.length,1);assert.equal(versions[0].inputRevision,2);
  assert.equal(versions[0].manifestSha256,'b'.repeat(64));
  assert.equal(failures.length,1);assert.equal(failures[0].attemptCount,3);
  assert.equal(failures[0].reason,'旧分片哈希改变');
  await restarted.clearSessionFailure(sessionKey);
  assert.equal((await restarted.localSessionFailures()).length,0);
  await restarted.recordSessionFailure({sessionKey, manifestSha256:'d'.repeat(64),
    category:'network', reason:'timeout', attemptCount:1, retryAt:100, updatedAt:200});
  await restarted.recordSessionCompletion({sessionKey, source:'watch_stop', completedSegments:3,
    totalSamples:48000, confirmedAt:1767225602000, manifestSha256:'e'.repeat(64), inputRevision:3});
  assert.equal((await restarted.localSessionFailures()).length,0,
    'manifest acknowledgement must atomically clear stale failure');
  console.log('PASS per-file receipts, manifest revision and conflict reason survive repository restart');
})().catch(error => {console.error(error);process.exitCode=1;});
