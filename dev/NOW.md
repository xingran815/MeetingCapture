# Now
Updated: 2026-11-06 · milestone 2 · issues #3, #4

**Next step:** `git switch -c m2-providers` from `main`, then build from `docs/specs/02-llm-providers.md`.
**How to check:** `scripts/check.sh` passes; each Done-when in that spec was seen working.

Done since last save:
- M1 merged (PR #11), verifier PASS; #1 and #2 closed with evidence.
- Default check takes about 80 s; `scripts/test-sweeps.sh` has 36 seeded cases.

Open loops:
- **Old SHAs still resolve on GitHub**, for example `bb04148`, and show the old email until GitHub purges them. The user decides whether to ask GitHub Support to purge.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed.
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`, which is all `Summarize.swift` uses today. M2's runner tests should use `GuardedTestCase`.
- Injected clock moved to M3 (D-23). Capture wasn't re-run after the Core move; M3's real call covers it.

Needs you: confirm GitHub's "Block command line pushes that expose my email" is on (global git email is already noreply).
