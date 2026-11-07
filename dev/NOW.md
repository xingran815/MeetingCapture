# Now
Updated: 2026-11-07 · M4 done and merged (PR 20, issues 7 and 8 closed). M5 next, in a new session.

**Next step:** start M5 (issue 9, branch `m5-desktop`) **in a new session**, as the user asked. First read `docs/specs/05-desktop.md`, then `dev/evidence/2026-11-07-m4-report.md`'s "For M5". Step 1 is six clickable HTML mock-ups only, no app code: **👤 the user picks one, and the build waits for that.** Check Apple's current Human Interface Guidelines at the time, not from memory. M5 settles the macOS target (`Package.swift` says 14; the spec says 26, D-51).
**How to check M4:** `dev/evidence/2026-11-07-m4-report.md`: each Done-when, every review finding with its test, and the assumptions with their reasons.

Open loops:
- **Checks:** pre-push is sweeps only. CI skips `…SlowTests` classes. `check.sh` runs unit tests on 4 workers (D-77, D-79); don't run other heavy jobs alongside. `MicCaptureRestartTests` uses the real audio engine: audio playing on the Mac can fail it.
- **Reviews run before the push** on local commits that passed `check.sh` (D-89), all needed ones in parallel; fix after all have finished.
- **Reports are built to skim** by the user's rules (D-87, D-88). Keep them in the app's report view.
- `--live-check` ignores `MEETINGCAPTURE_CLI_ONLY` (D-90, low).
- `testACLIThatExitedIsNotWaitedOnForItsBackgroundChild` has a tight 1.2 s limit; it failed once under load.
- **CI's E2E** uses committed clips (D-80).
- **Mic device changes mid-call** are untested on real hardware. Worth one manual unplug.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` stay unpushed (D-62).
- `README.md` is stale. M6 rewrites it.
- `NetworkRefusal` only covers `URLSession.shared`.

Needs you:
- M5's design pick, once the six mock-ups are up.
