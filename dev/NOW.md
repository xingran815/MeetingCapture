# Now
Updated: 2026-11-06 · milestone 3 · issues #5, #6

**Next step:** reviews run alongside CI on the M3 PR; fix findings in that PR. Then the 👤 check: the user records one short real call on the new build, and says whether it sounds right and labels correctly.
**How to check:** `scripts/check.sh` passes; CI green on the exact commit; verifier, deep review and `/security-review` pass; the user's yes.

Done since last save:
- M2.1 merged (PR #14), verifier PASS; #12 closed. Report: `dev/evidence/2026-11-06-m2.1-report.md`.
- `main` requires all seven CI checks, with no bypass. Merging needs green CI on the exact commit.
- M3 built on `m3-audio-speakers`: two tracks, M4A, retention, speakers, and the bug list. Real-audio trial: `dev/evidence/2026-11-06-m3-real-audio.md`.
- Manual checks left for the real call: Enter stops a flag-mode recording on a TTY; listen once after the Speex rate change; room noise on a separated mic track.

Open loops:
- **First `push` to `main` CI run:** check that it passed; it's the first test of the `event.before` range.
- **Old SHAs still resolve on GitHub**, for example `bb04148`, and show the old email until GitHub purges them. The user decides whether to ask GitHub Support to purge.
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former.
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- Injected clock for capture moved to M3 (D-23). Capture wasn't re-run after the Core move; M3's real call covers it.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- Confirm GitHub's "Block command line pushes that expose my email" is on (global git email is already noreply).
- `Package.swift` says macOS 14, the spec says macOS 26. Recommended: keep 14 and correct the spec.
