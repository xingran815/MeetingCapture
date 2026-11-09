# Now
Updated: 2026-11-09 · **M6 done; the refactor (M1–M6) is complete.** M6 on branch `m6-docs-release` (issue 10): SpeexDSP removed, README and CLAUDE.md rewritten, `SECURITY.md` and `docs/llm-usage.md` added, a final security pass. Report: `dev/evidence/2026-11-09-m6-report.md`.

**Next step:** no milestone is planned. New work starts from the open loops below; the user picks. Candidates: the M6 lows (D-100), turning on GitHub's private vulnerability reporting (the user's call, D-99), and the App lows left from M5.
**How to check M6:** the report has each Done-when and every finding with its test; the README's commands are the quickest end-to-end check.

Open loops:
- **Checks:** pre-push is sweeps only. CI skips `…SlowTests` classes. `check.sh` runs unit tests on 4 workers (D-77, D-79); don't run other heavy jobs alongside. `MicCaptureRestartTests` uses the real audio engine and can fail if another job uses the mic.
- **Reviews run before the push** on local commits that passed `check.sh` (D-89), all needed ones in parallel; fix after all have finished.
- **Reports are built to skim** by the user's rules (D-87, D-88).
- **M6 lows left (D-100):** `withoutAnyTokenShape` can split a value holding a capital TYPE name and digits so neither half is redacted; an imported recording without a sidecar or name stamp can take newer group reports as earlier. `e2e-full.sh` stops falsely in a clone under `/private/tmp` (path standardization).
- **M5.2 lows left:** the app doesn't say before Write the Report Again that group context will be used; an insight item is forced to "ai"; an earlier deadline can show as an owner-less to-do marked earlier.
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
- Whether to turn on GitHub's private vulnerability reporting (`SECURITY.md` asks for a detail-free issue until then).
