# Now
Updated: 2026-11-07 · M3.1 closing · next M3.2 · issue 16 closing; issue 17 next

**Next step:** wait for the user to say go. They said to stop after the M3.1 merge. Then M3.2 on `m3.2-echo` (issue 17, `docs/specs/03.2-echo.md`), then M4.
**How to check:** `git status` is clean, `main` matches `origin/main`, and issue 16 is closed with a comment giving Done-when 6's result.

**Don't start M3.2 without the user's go.**

**M3.2's first step:** the researcher looks for methods, and the user records the scripted test call. Only `m3-echo-off` holds raw echo today; `m3-check`, `m3-check2` and `m3-check3` went through the canceller, so they're for counts only. Use `/goal`.

Done since last save:
- M3.1 built and reviewed. Report: `dev/evidence/2026-11-07-m3.1-report.md`. The new hooks, test levels and review rules now apply.

Open loops:
- **M3.2's first PR:** check its logs for `Cache hit for restore-key: swiftbuild-main-`, which finishes proving M3.1's Done-when 6, and compare its run time with the report's table.
- **A worktree this session didn't make:** `.claude/worktrees/m3.2-echo`, locked, branch `worktree-m3.2-echo`, on the `main` from before M3.1, no commits of its own. Ask the user about it before M3.2.
- M5 settles the macOS setting: `Package.swift` says 14, untested; the specs say 26 (D-51).
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former, and the pre-push hook now checks it too (D-62).
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- Say go for M3.2.
- Say what the `m3.2-echo` worktree is for.
