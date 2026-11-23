# Now
Updated: 2026-11-23 · **M9 merged without its 👤 check: the "Transcribe this meeting?" prompt (issue 28, PR 35).** The user chose to merge first and try it on a real call later (D-109). Issue 28 stays open until then. Report: `dev/evidence/2026-11-21-m9-report.md`. Decisions D-108, D-109.

**Next step:** the user's real-call check. Install with `scripts/build-app.sh --install`, then: (1) start a call in a listed app; the panel shows after about 3 s (10 s in a browser, after macOS's Automation question); (2) Record, then hang up: "Call ended. Stop?" stops after 30 s; (3) start another call, Not This One: the menu bar shows `?` with Record This Call until the call ends. Passing it: tick the spec's 👤 line, set PLAN's M9 row to done, close issue 28. A problem: fix it on a new branch from `main`. No new milestone starts before that, unless the user says so.

Open loops:
- **M9 unsure until a real call:** Zoom or Teams may stop the mic on mute (over 10 s would count as the call ending), Safari's shared WebKit process, the panel over a full-screen call. M9 low left: the mic is polled on the main thread and the timer pauses while a menu is open. A recording started by hand never gets "Call ended. Stop?".
- **Swift 6.4 (installed 2026-11-21) defaults to the swiftbuild build system.** `check.sh` pins `--build-system native` (deprecated, to be removed in a future SwiftPM); `ci.sh`, `build-app.sh`, `install.sh` don't, and the two systems re-point `.build/debug`. Moving the unit runner to per-target bundles is the lasting fix: issue 33. The user chose to keep Swift 6.4 (Xcode 27.2, updated 2026-11-15) with the native pin until then.
- **M8 lows left:** the unshifted fit (no delay found) can treat a far track carrying the user's own voice at 0-1 ms (loopback or monitoring with `captureAllAudio`) as echo, so those lines show under a Speaker label; untested on a real setup. Each refit recomputes the same correlations three times (speed only). A periodic far side (hold music) could set the first-arrival lag a period early. Echo removal now takes about 19 s for a short CLI case in debug builds. Issue-31 goals not met: double-talk echo (real 4.09, synthetic 4.14 against 4.3), synthetic double-talk degradation, and the full-band ERLE, echo and degradation goals (report).
- **AEC lab machines:** the rented H200 is stopped (the user has its start and stop commands); the 2-core VM may still hold an old training queue.
- **M7 lows left:** a CLI call already under way isn't stopped when its job is cancelled (subprocess change, needs a security review); the shell's x+Enter doesn't ask; untested: cancelling a late-aborted job still queued, and a successful job finishing during a recording.
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
- The M9 real-call check (above).
- Whether to turn on GitHub's private vulnerability reporting (`SECURITY.md` asks for a detail-free issue until then).
