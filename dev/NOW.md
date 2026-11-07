# Now
Updated: 2026-11-07 · M5 done on branch `m5-desktop` (issue 9): the desktop app on `MeetingCaptureCore`, option 1 (D-91), macOS 26 (D-92). Report: `dev/evidence/2026-11-07-m5-report.md`.

**Next step:** M5.1, in a new session, on branch `m5.1-notebook` (issue 22). Spec: `docs/specs/05.1-notebook.md` (D-93): rename, notes, edit (desktop only) and delete to the Trash. Start with the file model: `<base>.edits.json` and `<base>.notes.md` merged at render, and the sidecar's new `reportFiles`, since delete depends on it (D-44). Deep review at the end (it deletes files). Then M5.2 (`docs/specs/05.2-groups.md`, D-94, issue 23), then M6.
**How to check M5:** the report has each Done-when, every review finding with its test, and the screenshots in `dev/evidence/m5-screens/`. Build the app with `scripts/build-app.sh --install`.

Open loops:
- **Checks:** pre-push is sweeps only. CI skips `…SlowTests` classes. `check.sh` runs unit tests on 4 workers (D-77, D-79); don't run other heavy jobs alongside. `MicCaptureRestartTests` uses the real audio engine: audio playing, or another job using the mic, can fail it (seen again in M5; alone it passes).
- **Reviews run before the push** on local commits that passed `check.sh` (D-89), all needed ones in parallel; fix after all have finished.
- **Reports are built to skim** by the user's rules (D-87, D-88). The app shows them in its report view.
- **App, left from M5:** VoiceOver reads the Re-run menu as "Refresh"; a progress event from a finished job can briefly reach the next queued one; the waveform shows the last 6 seconds, not the whole call (D-91 said the whole call; the user hasn't seen it live).
- **App signing:** with no Apple Development identity the app is signed ad-hoc and loses its permissions on each rebuild. Giving it to anyone else needs Developer ID and notarization (D-92).
- **Sidecar paths** aren't kept inside the output folder; nothing deletes from them today. Any new deletion code must check (D-44, M5 security review).
- `--live-check` ignores `MEETINGCAPTURE_CLI_ONLY` (D-90, low).
- `testACLIThatExitedIsNotWaitedOnForItsBackgroundChild` has a tight 1.2 s limit; it failed once under load.
- **CI's E2E** uses committed clips (D-80).
- **Mic device changes mid-call** are untested on real hardware. Worth one manual unplug.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` stay unpushed (D-62).
- `NetworkRefusal` only covers `URLSession.shared`.
- `~/Documents/huggingface/models/argmaxinc.m5-backup` holds the old copies of the small English and speaker models from the fresh-cache run; the user can delete it.

Needs you:
- Nothing for M6 to start.
