# Now
Updated: 2026-11-06 · milestone 2.1 · issue #12

**Next step:** on `m2.1-ci`, which already holds spec commit `9ed01b1`, rebase onto `main`, then fix `scripts/test-sweeps.sh` first: clear `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and related variables, with a regression test. Read issue #12 before the spec, because its decisions win over the spec.
**How to check:** `scripts/check.sh` passes; every required CI job passes on the M2.1 PR; each gate seen red for a real reason.

Done since last save:
- M2 merged (PR #13), verifier PASS; #3 and #4 closed. Report: `dev/evidence/2026-11-06-m2-report.md`.
- 72 unit tests; default check about 89 s. Redaction 72/73, 0 false positives.

Open loops:
- **Stay out of linked worktrees** until `scripts/test-sweeps.sh` is fixed; it can damage the real repo's git config there.
- M2.1 decisions to record: `main` requires CI, turned on only after every required job passes on the M2.1 PR; force-push and deletion are blocked, so a future approved force-push needs the ruleset changed first.
- Unexplained: a fresh checkout's first `swift build` failed once with "no versions of 'whisperkit' match". Find the cause before adding a retry.
- **Old SHAs still resolve on GitHub**, for example `bb04148`, and show the old email until GitHub purges them. The user decides whether to ask GitHub Support to purge.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed.
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- Injected clock for capture moved to M3 (D-23). Capture wasn't re-run after the Core move; M3's real call covers it.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you: confirm GitHub's "Block command line pushes that expose my email" is on (global git email is already noreply).
