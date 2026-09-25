# Isolated native voice-review acceptance

These files are test-only. They are not registered in the production module.

`Index.ets` renders the production inbox and Hds voice-review destination, using the production ViewModel, use cases, SQLite repository and AVPlayer. Only the remote port is substituted. Synthetic audio is a quiet tone, not a real voice or identity-validation fixture.

1. Back up `phone/src/main/ets/pages/Index.ets` outside tracked sources.
2. Run `python tools/quality/voice-review-device/generate.py` from the repository root.
3. Temporarily copy this directory's `Index.ets` onto the backed-up entry. Build the phone debug HAP and install it without clearing app data.
4. The entry uses only `voice-review-isolated.db`; it never starts the production device bridge or remote client. Reopening preserves pending annotation facts to test persistence. Do not change the database name to the production name.
5. Review two known samples (five windows each), an unknown sample (three mapped originals), and one history grant without audio. There are 81 synthetic context sentences; only mapped sentences are selectable. In the test entry only, the production connection-settings callback toggles the fake remote between connected/offline. Use it after audition to test a submission failure; it does not change actual networking.
6. Before leaving, use the test entry's “清理隔离数据” button and verify deletion. Restore the original entry, remove the generated `voice-review-fixture.json` rawfile, rebuild and reinstall the production HAP. Never uninstall/clear the real application.

Do not commit generated HAPs, databases, device logs or screenshots. Screenshots must be clearly described as real device rendering of production components with isolated synthetic data; server behavior beyond the fake acknowledgement is covered separately by ASR tests.
