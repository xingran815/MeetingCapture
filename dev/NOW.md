# Now
Updated: 2026-11-06 · milestone 3 · issues #5, #6

**Next step:** the 👤 check. Two real calls had audible speaker echo, now fixed by D-58 but unproven on a real call. The user records one more short real call on the new build, and says whether the echo is gone and the labels are right. Measure the mic-after-system delay on it with 10 ms envelopes. Then write the M3 report, add the two lows below to D-57, merge, close #5 and #6, and stop.
**Re-checks on `ce4d8c1`:** verifier PASS on changed lines; deep review approve; security nothing at the bar. Lows to add at close: re-transcribing can print "won't be deleted" on a recording retention can still delete; the "part 2" speaker note can appear with no such label in the transcript. Test gap: no test of a system-side noise track with a throwing detector, and no `noise-only-system` E2E case; one manual run on white noise passed.
**How to check:** `scripts/check.sh` passes; CI green on the exact commit; verifier, deep review and `/security-review` pass; the user's yes.

**Stop after M3 closes.** The user said so on 2026-11-06: don't start M4 until they say to. This overrides "start the next milestone" for this one close.

Done since last save:
- M2.1 merged (PR #14), verifier PASS; #12 closed. Report: `dev/evidence/2026-11-06-m2.1-report.md`.
- `main` requires all seven CI checks, with no bypass. Merging needs green CI on the exact commit.
- M3 built on `m3-audio-speakers`: two tracks, M4A, retention, speakers, and the bug list. Real-audio trial: `dev/evidence/2026-11-06-m3-real-audio.md`.
- Manual checks left for the real call: Enter stops a flag-mode recording on a TTY; listen once after the Speex rate change; room noise on a separated mic track.

Open loops:
- M5 settles the macOS setting: `Package.swift` says 14, untested; the specs say 26 (D-51).
- **First `push` to `main` CI run:** check that it passed; it's the first test of the `event.before` range.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former.
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- Injected clock for capture moved to M3 (D-23). Capture wasn't re-run after the Core move; M3's real call covers it.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- The 👤 real call, once the fixes are pushed and CI is green.
