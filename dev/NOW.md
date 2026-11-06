# Now
Updated: 2026-11-06 · milestone 3 · issues #5, #6

**Next step:** the user chose transcribe and flag for noise-like tracks (D-56). Finish its tests, push, and re-check the changed lines alongside CI. Then the 👤 check: the user records one short real call on the new build, and says whether it sounds right and labels correctly.
**Re-checks on `8156d1d`:** CI green; verifier PASS on changed lines; security nothing at the bar; deep review one should-fix, which D-56 answers. Its lows are D-57.
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
