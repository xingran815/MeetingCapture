# Now
Updated: 2026-11-07 · M3 closing · next M3.1, then M3.2 · issues #5, #6 closing; #16, #17 next

**Next step:** wait for the user to say go. They said to stop when M3 finishes. Then M3.1 on `m3.1-faster-checks` (issue 16), then M3.2 on `m3.2-echo` (issue 17, `docs/specs/03.2-echo.md`), then M4.
**How to check:** `git status` is clean, `main` matches `origin/main`, and issues 5 and 6 are closed with a comment saying the echo moves to M3.2.

**Don't start M3.1 or later without the user's go.** The user said on 2026-11-06 to stop when M3 finishes.

**M3.2's first step:** the researcher looks for methods, and the user records the scripted test call. Only `m3-echo-off` holds raw echo today; `m3-check`, `m3-check2` and `m3-check3` went through the canceller, so they're for counts only. Use `/goal`.

Done since last save:
- M3 built, reviewed and merged. Report: `dev/evidence/2026-11-07-m3-report.md`.
- Real calls: `dev/evidence/2026-11-06-m3-real-audio.md` and the report.

Open loops:
- M3.1's spec is `docs/specs/03.1-faster-checks.md` (issue 16, D-61). Its new hooks and review rules apply only once it merges.
- M5 settles the macOS setting: `Package.swift` says 14, untested; the specs say 26 (D-51).
- **First `push` to `main` CI run:** check that it passed; it's the first test of the `event.before` range.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former.
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- Say go for M3.1.
