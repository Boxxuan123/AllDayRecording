// Synthetic 7/90/365 day cost gate using the production SQLite repository.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Repository, UseCases, stores } = require('./phone-sqlite-harness.cjs');

const id = n => String(n).padStart(26, '0');
const now = () => Number(process.hrtime.bigint()) / 1e6;

(async () => {
  for (const days of [7, 90, 365]) {
    const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'phone-paging-scale-')), 'synthetic.db');
    const repository = await Repository.open({ databasePath });
    let sequence = 0;
    for (let day = 0; day < days; day++) {
      const date = new Date(Date.UTC(2025, 0, 1 + day)).toISOString();
      const sessionId = id(10000 + day);
      await repository.applyChange({ sequence: ++sequence, resource_type: 'recording_session',
        resource_id: sessionId, revision: 1, operation: 'upsert',
        resource: { session_id: sessionId, captured_start: date } });
      for (let item = 0; item < 10; item++) {
        const utteranceId = id(100000 + day * 10 + item);
        await repository.applyChange({ sequence: ++sequence, resource_type: 'utterance',
          resource_id: utteranceId, revision: 1, operation: 'upsert',
          resource: { utterance_id: utteranceId, session_id: sessionId,
            speaker_track_id: null, speaker_label: null, original_speaker_track_id: null,
            original_speaker_label: null, identity: 'unknown', original_identity: 'unknown',
            identity_evidence: {}, start_ms: item * 1000, end_ms: item * 1000 + 500,
            start_at: date, end_at: new Date(Date.parse(date) + 500).toISOString(),
            text: 'synthetic', original_text: 'synthetic',
            revision: 1, status: 'active', evidence: {} } });
      }
    }
    const useCases = new UseCases(repository, { list: async () => [] }, { isPaired: async () => false });
    let decoded = 0;
    const parse = JSON.parse;
    JSON.parse = (...args) => {
      if (typeof args[0] === 'string' && args[0].includes('"original_identity"')) decoded++;
      return parse(...args);
    };
    let snapshot;
    const homeStarted = now();
    try { snapshot = await useCases.loadCached([]); }
    finally { JSON.parse = parse; }
    const homeMs = now() - homeStarted;
    assert.equal(decoded, 0, 'home decoded historical transcript payloads');
    assert.equal(snapshot.sessions.length, days);
    const opened = snapshot.sessions[0];
    const sessionStarted = now();
    await useCases.loadSessionUtterancePage(opened, 50);
    const sessionMs = now() - sessionStarted;
    assert.equal(opened.utterances.length, 10);
    assert.equal(opened.utteranceCount, 10);
    assert.equal(snapshot.sessions.reduce((sum, card) => sum + card.utterances.length, 0), 10);
    console.log(JSON.stringify({ days, totalUtterances: days * 10,
      homeTranscriptPayloads: decoded, firstSessionRows: opened.utterances.length,
      residentUtteranceRows: snapshot.sessions.reduce((sum, card) => sum + card.utterances.length, 0),
      homeMs: Number(homeMs.toFixed(2)), firstSessionMs: Number(sessionMs.toFixed(2)) }));
    stores.at(-1).db.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
