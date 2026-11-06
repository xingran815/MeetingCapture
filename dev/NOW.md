# Now
Updated: 2026-11-06 · milestone 1 · issues #1, #2

**Next step:** on branch `m1-safety-gates`, build `scripts/sweep.sh` and the git hooks from `docs/specs/01-safety-and-tests.md`, then prove them with seeded leaks.
**How to check:** a seeded fake key, an email, a `Co-Authored-By: Claude` line and a staged `.wav` are each refused at commit.

Done since last save:
- Interview finished; decisions in `dev/DECISIONS.md`.
- Spikes run; evidence in `dev/evidence/2026-11-06-spikes.md`.
- Issues #1–#10 created; specs in `docs/specs/`; rules at the end of `CLAUDE.md`.
- Readiness report with quiz: https://claude.ai/artifact/9VWdBhk1yAz6kR2g8sR9vp (private to the owner).

Open loops:
- **Do not push yet.** `main` still has 5 unpushed commits with the old email; pushing waits for the M1 rewrite (D-05).
- Repo-local author is already the noreply identity. `feature/coding-interview` stays local.
- Old local branch `feat/multi-provider-reasoning` is fully contained in `main`; leave it unpushed.

Needs you: set the global git email to the noreply address, and turn on GitHub's "Block command line pushes that expose my email".
