# Now
Updated: 2026-11-06 · milestone 1 · issues #1, #2

**Next step:** read the `verifier` report on the M1 PR, fix findings in that PR, then merge with `git switch main && git merge --ff-only m1-safety-gates && git push origin main`, comment on and close #1 and #2.
**How to check:** `scripts/check.sh` passes; each Done-when in `docs/specs/01-safety-and-tests.md` was seen working.

Done since last save:
- Sweeps, hooks and `scripts/setup.sh`; `scripts/test-sweeps.sh` proves 36 seeded cases.
- `MeetingCaptureCore` split out; 10 unit tests; `scripts/e2e.sh`; `scripts/check.sh` default takes about 90 s.
- History rewritten and force-pushed (D-05 used up). GitHub serves only noreply emails on `main`.

Open loops:
- **Old SHAs still resolve on GitHub**, for example `bb04148`, and show the old email until GitHub purges them. The user decides whether to ask GitHub Support to purge.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed.
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`, which is all `Summarize.swift` uses today. M2's fake-CLI runner tests should keep to `GuardedTestCase`.

Needs you: confirm GitHub's "Block command line pushes that expose my email" is on (global git email is already noreply).
