// Test-only explicit session opening. Home snapshots intentionally contain no transcript payloads.
async function loadFixtureTranscript(useCases, snapshot, targetCount = Number.MAX_SAFE_INTEGER) {
  for (const session of snapshot.sessions) {
    await useCases.loadSessionUtterancePage(session, Math.min(session.utteranceCount, targetCount));
  }
  return snapshot;
}

module.exports = { loadFixtureTranscript };
