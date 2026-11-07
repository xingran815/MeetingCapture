# Now
Updated: 2026-11-07 · M5.1 done on branch `m5.1-notebook` (issue 22): rename, notes, desktop-only editing and delete to the Trash (D-93, D-95). Report: `dev/evidence/2026-11-07-m5.1-report.md`.

**Next step:** M5.2, in a new session, on branch `m5.2-groups` (issue 23). Spec: `docs/specs/05.2-groups.md` (D-94). Start with `groups.json` in the output folder and the allow-listed context from other reports, redacted in one token space with the transcript (`SummaryPipeline.redactTogether` from M5.1 is the pattern). The 👤 check compares a report with and without group context. Then M6.
**How to check M5.1:** the report has each Done-when, every review finding with its test, and the screenshots in `dev/evidence/m51-screens/`. Build the app with `scripts/build-app.sh --install`.

Open loops:
- **Checks:** pre-push is sweeps only. CI skips `…SlowTests` classes. `check.sh` runs unit tests on 4 workers (D-77, D-79); don't run other heavy jobs alongside. `MicCaptureRestartTests` uses the real audio engine and can fail if another job uses the mic.
- **Reviews run before the push** on local commits that passed `check.sh` (D-89), all needed ones in parallel; fix after all have finished.
- **Reports are built to skim** by the user's rules (D-87, D-88).
- **M5.1 lows left:** the review step never sees notes; flag-mode `--summarize-only` doesn't cap notes at 100k; a failed write after Drop Edits loses the edits; a page added after a delete was confirmed is left unlisted.
- **App, left from M5:** VoiceOver reads the Re-run menu as "Refresh"; a progress event from a finished job can briefly reach the next queued one; the waveform shows the last 6 seconds, not the whole call.
- **App signing:** with no Apple Development identity the app is signed ad-hoc and loses its permissions on each rebuild (D-92).
- **App screenshots in tests:** launch with `MEETINGCAPTURE_E2E=1 MEETINGCAPTURE_HOME=<temp home>` and invented files; a hand-written sidecar needs `speakerNames`.
- `--live-check` ignores `MEETINGCAPTURE_CLI_ONLY` (D-90, low).
- `testACLIThatExitedIsNotWaitedOnForItsBackgroundChild` has a tight 1.2 s limit; it failed once under load.
- **Mic device changes mid-call** are untested on real hardware.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` stay unpushed (D-62).
- `NetworkRefusal` only covers `URLSession.shared`.

Needs you:
- Nothing for M5.2 to start.
