# Now
Updated: 2026-11-07 · M3.2 done and merged (PR 19, issue 17 closed). M4 next, in a new session.

**Next step:** start M4 (issues 7 and 8, branch `m4-summaries-html`) **in a new session**, as the user asked (CLAUDE.md, closing step 4). First read `docs/specs/04-summaries-html.md` and `docs/specs/02-llm-providers.md`, then `dev/evidence/2026-11-07-m3.2-report.md`'s "What M4 needs to know". M4 needs a deep review and a 👤 check: the user reads a live report.
**How to check M3.2:** `dev/evidence/2026-11-07-m3.2-report.md`, which holds every figure and each assumption with its reason.

**M3.2's takes:** `~/Documents/MeetingCapture-m3.2-raw/TAKE-NOTES.md`. `m3-check`, `m3-check2` and `m3-check3` are for counts only.

Open loops:
- **Checks:** pre-push is sweeps only (seconds). CI skips `…SlowTests` classes. `check.sh` runs unit tests on 4 workers (D-77, D-79); don't run other heavy jobs alongside.
- **CI's E2E** uses committed clips, since `say` wrote empty audio on the runner (D-80). Audio files are refused by the sweep except those two, by exact name.
- **Mic device changes mid-call** are untested on real hardware (report, After the listen). Worth one manual unplug.
- M5 settles the macOS setting: `Package.swift` says 14, untested; the specs say 26 (D-51).
- Local `feature/coding-interview` and `feat/multi-provider-reasoning` keep old metadata and stay unpushed. `scripts/protected-commits.sha256` is a snapshot of the former, and the pre-push hook now checks it too (D-62).
- `README.md` is stale (still says Qianfan is the default). M6 rewrites it; `docs/specs/06-docs-release.md`.
- `NetworkRefusal` only covers `URLSession.shared`.
- From M2, still unsure: Claude's `ind-07` rating gap has no saved rater note; quality tables predate the softened fixture values.

Needs you:
- Nothing blocking. Say if your verdict shouldn't stand in for M3.2's unmet targets (D-78).
