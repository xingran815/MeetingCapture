# M1 — Safety gates and fast tests

**Goal:** nothing with an email, key or failing test can be committed or pushed, and tests run in minutes without long audio.

## Package split
Move everything testable out of `main.swift` into a `MeetingCaptureCore` library target. `MeetingCaptureCLI` stays a thin executable. Add `Tests/MeetingCaptureCoreTests`. An executable target can't be imported by tests, so this comes first.

## `scripts/check.sh`
| Mode | Runs | Used by | Budget |
|---|---|---|---|
| `--fast` | build, unit tests, sweep of staged changes | pre-commit | < 2 min |
| default | `--fast` + E2E with short audio + sweep of everything outgoing | pre-push, verifier | < 8 min |
| `--live` | default + one small real call per logged-in CLI | by hand only | spends subscription usage |

## Speeding up tests
Long behaviour is tested by injecting the length, never by waiting.
- `MixingWriter` takes `chunkFrameLimit` as a parameter (default 30 min); tests use 2 seconds.
- Duration, retention and timer code takes an injected clock.
- Fixtures are generated with `say` (2–3 voices, 5–30 s) and `afconvert`, cached in `dev/tmp/fixtures/`.
- E2E uses an already-cached small Whisper model and skips with a clear message if it's missing.
- LLM calls hit fake `claude` and `codex` executables placed first on `PATH`, replaying recorded output. Any real process or network use without `--live` fails the test.

## Sweeps: `scripts/sweep.sh`
Regex only; no third-party scanner, because installing one needs approval and these formats are enough.

| Sweep | Checks | Applies to |
|---|---|---|
| Identity | Any email in author or committer that isn't `*@users.noreply.github.com`; any email in tracked text outside an allowlist (`example.com/.org/.cn`, `noreply`); `/Users/<name>/` paths | staged files, outgoing commits and their messages |
| AI attribution | `Co-Authored-By:` naming Claude, Anthropic, Codex or GPT | commit messages |
| Secrets | `sk-…`, `sk-ant-…`, `gh[pousr]_…`, `AKIA…`, `xox?-…`, private key headers, `*_API_KEY=<value>`, tokens in URLs, 32+ hex after `key`/`token`/`secret` | staged files, outgoing diffs |
| Sensitive files | `llm_api_keys.json`, `auth.json`, `.env`, `*.wav`, `*.m4a`, `*.mp3`, real transcripts and reports | staged and outgoing files |
| Code security | `Process` with a shell (`/bin/sh -c`, `zsh -c`), `--dangerously`, `--no-verify`, logging an API key or `Authorization` value, literal invisible Unicode characters | staged files |
| Branch rule | Any push of `feature/coding-interview`, or a commit descending from it | pre-push |

Allowlist: `dev/spikes/`, `Tests/Fixtures/` may hold obviously fake values containing `FAKE` or `example`, listed by exact pattern in `scripts/sweep-allow.txt`.

## Git hooks
`.githooks/pre-commit`, `commit-msg`, `pre-push`; `scripts/setup.sh` sets `core.hooksPath` and is called by `install.sh`. Hooks fail closed if the sweep script is missing.

## History rewrite (D-05), once only
Do this after the sweep passes on a seeded leak.
1. `git bundle create ~/Documents/Projects/MeetingCapture-pre-rewrite.bundle --all`, kept outside the repo, because the rewrite is hard to undo.
2. `git filter-branch --env-filter …` over `main` and `m1-safety-gates` only: set author and committer to the repo-local noreply identity; `--msg-filter` strips AI `Co-Authored-By` lines. Built-in git, because `git-filter-repo` isn't installed.
3. Check: `git log main --format='%ae%n%ce%n%B'` passes the identity and attribution sweeps. `LICENSE` stays as it is; the user said only the email matters.
4. `git push --force-with-lease origin main`, and the branch, by name. Nothing else.
5. Check with `gh api`: every commit email served by GitHub is noreply, and `.patch` of the new tip shows noreply.
6. Tell the user: old SHAs may stay reachable until GitHub purges them, and copies elsewhere can't be recalled.

`feature/coding-interview` is left alone, stays local and keeps its old metadata.

## Done when
- [ ] A seeded fake key, a seeded real-looking email, a `Co-Authored-By: Claude` line and a staged `.wav` are each blocked at commit, with the rule named.
- [ ] A push of `feature/coding-interview` is refused by the hook, shown with a dry run against a local bare repo.
- [ ] A 2-second chunk test proves rotation, and an E2E run proves record-free transcribe on a short fixture; default check takes under 8 min.
- [ ] GitHub serves only noreply emails for all commits on `main`.
- [ ] A test run with no fake CLI on `PATH` fails rather than calling a real model.
