# M6 — Docs, security pass, final check

**Goal:** the docs match the product, and a last independent pass finds what the earlier ones missed.

## Docs
- `README.md`: what it is, terminal and desktop, subscription or API setup, privacy flow, redaction limits (names aren't caught), retention, recording consent, troubleshooting.
- `CLAUDE.md`: rewrite the v0.6 sections, including the file map and gotchas; keep the devkit block.
- `docs/llm-usage.md`: subscription routes, what each limit means, the personal-use note: use your own login on the official CLIs, and anyone else uses their own.
- `SECURITY.md`: how to report, what leaves the machine, and what the sweeps do and don't catch.
- `--help` matches the behaviour; no references to Qianfan, Kimi, the mono format, or `swift run`.

## Remove SpeexDSP (D-81)
The app hasn't built SpeexDSP since M3.2 (D-66); it was kept only so the echo lab could rerun the Speex baseline. The user decided M6 deletes it:
- `Sources/Speexdsp/` (vendored source, its `LICENSE` and `UPSTREAM.md`).
- `scripts/echo-lab/speex_run.c` and the Speex method in `scripts/echo-lab/methods.py`.
- The vendored exceptions for it in `scripts/lint.sh` and `scripts/sweep.sh`, and any lint, format or CI exclusion that names it.
- The `Sources/Speexdsp/` line in CLAUDE.md's file map. M3 and M3.2 reports keep their Speex figures as history.

## Security pass
Run `/security-review` and the `deep-reviewer` agent in parallel with each other on the whole milestone, after CI. Also check by hand:
- Fresh clone: `scripts/setup.sh` installs the hooks, and `scripts/check.sh --full` passes.
- Full-history sweep on `main` and every commit email on GitHub.
- `feature/coding-interview` is absent from the remote.
- No real audio, transcript or report in the repo or its history.
- The app and CLI log no keys, tokens or transcript text.

## Done when
- [ ] SpeexDSP is gone: `git grep -i speex` finds only the M3 and M3.2 history (specs, reports, decisions), and `scripts/check.sh --full` passes without it.
- [ ] Every command in the README was run, with output seen.
- [ ] Verifier passes, deep review findings fixed in this PR.
- [ ] All issues closed with evidence comments, and `dev/NOW.md` is current.
- [ ] Lessons saved with the `lesson` skill where something hurt.
