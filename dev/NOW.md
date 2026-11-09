# Now
Updated: 2026-11-09 · M5.2 done on branch `m5.2-groups` (issue 23, PR 25): groups in `groups.json` whose earlier reports become allow-listed, redacted context; facts kept from them are marked "From an earlier report" (D-94, D-96, D-97, D-98). Report: `dev/evidence/2026-11-09-m5.2-report.md`.

**Next step:** M6, in a new session, on branch `m6-docs-release` (issue 10). Spec: `docs/specs/06-docs-release.md`. Start by removing `Sources/Speexdsp/` (D-81) and proving `git grep -i speex` finds only history; then rewrite the v0.6 sections of CLAUDE.md and the README for M4–M5.2 (subscription CLIs, reports, the app, notebook, groups), running every README command. Deep review and `/security-review` run in parallel before the push (D-89); include the group context path (`GroupContextBuilder.render`, `redactTogether`, `Redactor.safePrefix`).
**How to check M5.2:** the report has each Done-when and every finding with its test. `scripts/live-group-report.sh` reruns the 👤 comparison (about 15 CLI calls; writes to `dev/tmp/live-group/`).

Open loops:
- **Checks:** pre-push is sweeps only. CI skips `…SlowTests` classes. `check.sh` runs unit tests on 4 workers (D-77, D-79); don't run other heavy jobs alongside. `MicCaptureRestartTests` uses the real audio engine and can fail if another job uses the mic.
- **Reviews run before the push** on local commits that passed `check.sh` (D-89), all needed ones in parallel; fix after all have finished.
- **Reports are built to skim** by the user's rules (D-87, D-88).
- **M5.2 lows left:** the app doesn't say before Write the Report Again that group context will be used; `Redactor.safePrefix` makes one pass instead of repeating until stable; an insight item is forced to "ai"; an earlier deadline can show as an owner-less to-do marked earlier.
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
- Nothing for M6 to start.
