# Now
Updated: 2026-11-07 · M3.2 listen passed, PR 19 open, re-check of the post-listen code next

**Next step:** M3.2's listen passed (D-78). Since the last review, new code: `_clean` as two channels (D-76), the mic tap following the device's format, and the mic restarting after a device change. Re-check only those lines (reviewer, then verifier against `dev/tmp/check-full.txt`), read CI on the pushed commit, then merge PR 19 by the local rule, close issue 17, delete the worktree, and start M4.
**How to check:** `dev/evidence/2026-11-07-m3.2-report.md`, which holds every figure and each assumption with its reason.

**M3.2's takes:** `~/Documents/MeetingCapture-m3.2-raw/TAKE-NOTES.md`. `m3-check`, `m3-check2` and `m3-check3` are for counts only.

Open loops:
- **Pushing:** use `GIT_SSH_COMMAND="ssh -o ServerAliveInterval=30"` (D-75), and give the hook about 7 minutes.
- **PR 19's CI:** merge needs all 7 green on the merged commit. E2E failed once on `4289e08`, unexplained (report, Gates). M3.1's Done-when 6 is proven by its first run.
- **Worktree `.claude/worktrees/m3.2-echo`:** locked, branch `worktree-m3.2-echo`, only made audio for M3.2. The user said (2026-11-07) to delete it when M3.2 finishes. It holds the uncommitted `keep-wav.patch` change, a saved copy of which is in the takes folder, plus 50 MB of ignored `dev/tmp`. Delete when M3.2 closes, and report what was removed.
- M5 settles the macOS setting: `Package.swift` says 14, untested; the specs say 26 (D-51).
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former, and the pre-push hook now checks it too (D-62).
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- The final listen and label check on a new real call, M3.2's item 8.
- Decide M3.2's missed targets (D-68), the speaker count (D-69), and whether to allow the AEC3 build (D-70).
- Say go if M4 should start before the listen (D-71).
