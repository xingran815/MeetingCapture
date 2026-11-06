# M6 — Docs, security pass, final check

**Goal:** the docs match the product, and a last independent pass finds what the earlier ones missed.

## Docs
- `README.md`: what it is, terminal and desktop, subscription or API setup, privacy flow, redaction limits (names aren't caught), retention, recording consent, troubleshooting.
- `CLAUDE.md`: rewrite the v0.6 sections, including the file map and gotchas; keep the devkit block.
- `docs/llm-usage.md`: subscription routes, what each limit means, the personal-use note: use your own login on the official CLIs, and anyone else uses their own.
- `SECURITY.md`: how to report, what leaves the machine, and what the sweeps do and don't catch.
- `--help` matches the behaviour; no references to Qianfan, Kimi, the mono format, or `swift run`.

## Security pass
Run `/security-review`, then the `deep-reviewer` agent on the whole milestone. Also check by hand:
- Fresh clone: `scripts/setup.sh` installs the hooks, and `scripts/check.sh` passes.
- Full-history sweep on `main` and every commit email on GitHub.
- `feature/coding-interview` is absent from the remote.
- No real audio, transcript or report in the repo or its history.
- The app and CLI log no keys, tokens or transcript text.

## Done when
- [ ] Every command in the README was run, with output seen.
- [ ] Verifier passes, deep review findings fixed in this PR.
- [ ] All issues closed with evidence comments, and `dev/NOW.md` is current.
- [ ] Lessons saved with the `lesson` skill where something hurt.
