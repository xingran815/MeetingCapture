# Plan — MeetingCapture refactor
Status: active · mode: 🏢 light production (adopted) · started 2026-11-06 · devkit 0.3.0

## Intention
For its owner, a professional meeting helper (terminal and macOS app): speaker-labelled transcripts, scenario-based summaries through existing subscriptions, HTML reports, and no email or key leaks.

**Done when**
1. A real meeting gives `<timestamp>_<topic>.html` with time, speaker and a fitting summary.
2. The app and the terminal both do this; the terminal has every app feature, plus finer config.
3. Tests and sweeps block a bad commit or push, shown with seeded leaks.

**Must not:** push or merge `feature/coding-interview`; put an email, key or real transcript in anything pushed.
**Out of scope:** LangChain and LangGraph, distribution beyond personal use (notarization, updates), real-time transcription, spoken-name redaction.

## Milestones
| # | Milestone | Issues | Branch | Verify (Sonnet) | Deep review (Opus) | User check | Status |
|---|---|---|---|---|---|---|---|
| 1 | Safety gates, fast tests, history rewrite | #1 #2 | `m1-safety-gates` | yes | no | no | done |
| 2 | Providers and redaction | #3 #4 | `m2-providers` | yes | no | no | done |
| 2.1 | CI: build, tests, leak scan, lint | #12 | `m2.1-ci` | yes | no | no | done |
| 3 | M4A, retention, speakers, bug fixes | #5 #6 | `m3-audio-speakers` | yes | **yes** | short real call | todo |
| 4 | Scenario summaries and HTML | #7 #8 | `m4-summaries-html` | yes | **yes** | reads a live report | todo |
| 5 | Six designs, then the app | #9 | `m5-desktop` | yes | no | **picks a design** | todo |
| 6 | Docs and security pass | #10 | `m6-docs-release` | yes | **yes** | no | todo |

Each milestone's Done-when list is in `docs/specs/0<n>-*.md`.

## How each milestone runs
1. Branch from `main`. Build in the main session.
2. Commit each logical change after `scripts/check.sh --fast` passes (hooks enforce it after M1).
3. Push the branch; open one PR that says `Closes` for the milestone's issues.
4. `verifier` agent checks every Done-when item. After M3, M4 and M6, `deep-reviewer` agent also reviews.
5. Fix findings in the same PR, turning each into a test where possible. Lows don't block; re-checks cover changed lines only.
6. Merge with `git merge --ff-only` and push `main`. Comment on and close the issues with evidence. Update `dev/NOW.md`.

`next` keeps going until a milestone's merge, then saves; it stops at 👤 checks.

## Cut order
Cut first: polish on the `lecture` and `one_on_one` templates; Codex app-server limits (use error text); `--zh-script`.
Never cut: sweeps and hooks, WAV-first conversion check, retention sparing old files, HTML escaping, tools off for transcript calls.

## Roles
| Role | Agent | Source |
|---|---|---|
| Coordinator and builder | main session | here |
| Verifier | `verifier` (Sonnet) | global devkit |
| Deep reviewer | `deep-reviewer` (Opus) | `.claude/agents/deep-reviewer.md`, new because it pins the model and this project's failure modes |

## Skills
| Skill | Use for | Source |
|---|---|---|
| `next` | Resume and save | global devkit |
| `/security-review` | M6 pass | built-in |
| `lesson` | Save pitfalls | global devkit |

## Check command
`scripts/check.sh`. Run it before saying anything is done.

## Lessons applied
- Keep state in files so a new session resumes in a minute — devkit `experience/lessons/2026-10-21-state-in-files.md`
- Model runners: no shell, allow-listed env, cwd outside the repo, login check, tests block real processes — `2026-11-03-model-runners-without-shell.md`
- Never type email, tokens or keys into commands, commits or prompts — `2026-10-31-no-secrets-in-output.md`
- One deep review per milestone, lows never block, re-checks see changed lines — `2026-10-31-fewer-deeper-checks.md`
- Reviewer finds attack paths; verifier runs last, after all fix rounds — `2026-11-03-reviewer-and-verifier-both.md`
- Long commands in the background with a limit and a log — `2026-10-21-long-commands-hang.md`
- No AI `Co-Authored-By` lines — `2026-10-22-no-ai-coauthor-in-commits.md`
- Write invisible characters as `\uXXXX`, with a test — `2026-11-03-invisible-chars-as-escapes.md`
