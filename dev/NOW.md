# Now
Updated: 2026-11-07 · M3.1 closing · next M3.2 · issue 16 closing; issue 17 next

**Next step:** M3.2 is running on `m3.2-echo` (issue 17, `docs/specs/03.2-echo.md`); the user said go on 2026-11-07, recorded the takes, and handed off overnight. Each milestone's report must list what was assumed and why.
**How to check:** the developer subagent's figures are in `dev/tmp/echo-lab/RESULTS.md` (gitignored, so copy them into the report).

**M3.2's takes:** `~/Documents/MeetingCapture-m3.2-raw/TAKE-NOTES.md`. `main-3` is the main take, `main-2` the quieter one, `start1` to `start4` for lag. The other side is a synthetic voice. Researcher finished: no source gives a verified 30 dB on this kind of hardware, so measurements decide. `m3-check`, `m3-check2` and `m3-check3` are for counts only.

Done since last save:
- M3.1 built and reviewed. Report: `dev/evidence/2026-11-07-m3.1-report.md`. The new hooks, test levels and review rules now apply.

Open loops:
- **M3.2's first PR:** check its logs for `Cache hit for restore-key: swiftbuild-main-`, which finishes proving M3.1's Done-when 6, and compare its run time with the report's table.
- **Worktree `.claude/worktrees/m3.2-echo`:** locked, branch `worktree-m3.2-echo`, only made audio for M3.2. The user said (2026-11-07) to delete it when M3.2 finishes. Look at it first, and report what was removed.
- M5 settles the macOS setting: `Package.swift` says 14, untested; the specs say 26 (D-51).
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former, and the pre-push hook now checks it too (D-62).
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- The final listen and label check on a new real call, M3.2's item 8.
