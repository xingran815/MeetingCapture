# M2 — LLM providers and redaction

**Goal:** three model tiers through the user's subscriptions, knowing when usage is full, with formatted sensitive values kept out of every request.

## Decisions
- **No LangChain or LangGraph.** They don't provide subscription access, and a short pipeline doesn't justify a Python runtime in a Swift app. See `dev/evidence/2026-11-06-spikes.md`.
- **No proxies or third-party SDKs.** Local proxies that reuse login tokens conflict with Anthropic's rule against intermediating credentials. A small `Process` wrapper around the official CLIs is about the size of the third-party Swift SDK's useful part.
- Unmodified `claude` and `codex` only. The app never reads, stores or forwards their login tokens.

## Provider order
| Situation | Behaviour |
|---|---|
| Both CLIs logged in | **Claude runs all tiers.** Never mix tiers across CLIs. |
| Claude's usage is full, before or during a run | Codex runs the remaining steps; the report says so. Fallback happens only for a full limit, not for other errors. |
| One CLI available | That one. |
| No CLI, or the user selects an API profile | The chosen API profile. DeepSeek stays as a preset. |

Primary CLI is a setting in both UIs. Keep OpenAI, Anthropic API, Ollama and custom profiles (terminal config). **Remove Qianfan and Kimi:** the preset, default profile and legacy-key paths. Migration: a saved Qianfan profile and its key entry are removed on load with one printed notice; if nothing remains, use the CLI order. Keep the `thinking` request format for DeepSeek, renamed from `kimi`, reading the old stored value.

## Tiers
| Tier | Job | Claude | Codex (Plus) | Reasoning |
|---|---|---|---|---|
| Cheap | Topic and scenario | `haiku` | `gpt-6-luna` | none |
| Normal | Sections | `sonnet` | `gpt-6.1-sol` | default |
| Frontier | Review | `opus` | `gpt-6-astra` | default |

Model names live in config, because they change. Codex tier quality is untested and needs a `--live` comparison in this milestone.

## Calling the CLIs
All calls use `Process` with an argument array, no shell, a cwd in a new empty temp directory, input on stdin, and an **allow-listed environment** (`HOME`, `PATH`, `USER`, `TMPDIR`), because a set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` would bill the API.

```text
claude -p --safe-mode --strict-mcp-config --no-session-persistence --tools "" \
       --model <tier> --output-format stream-json --verbose --json-schema <schema> --system-prompt <prompt>
codex exec --json --output-schema <file> --sandbox read-only --skip-git-repo-check --ephemeral \
       --ignore-user-config --ignore-rules -m <model>
```
Take Codex's feature-off list from Job Radar's `src/lib/ai/providers/codex-features.ts`. Without it, Codex loaded about 17k input tokens of user context for a one-word answer. Refuse to run if `apiKeySource` is set or `codex login status` doesn't say ChatGPT, unless the user opted into API billing.

**Tools stay off for any call containing transcript text.** Web search is a separate call: `--tools WebSearch --allowedTools WebSearch` or `codex --search exec`, whose prompt holds only generic concept names and never a name, quote or personal detail. Claude's result reported `web_search_requests: 0` even though the tool was called, so count tool-use events instead.

## Knowing usage is full
| CLI | Source | Status |
|---|---|---|
| Claude | `rate_limit_event` in `stream-json`: `status`, `utilization` per window, `resetsAt` | Seen working |
| Codex | `codex app-server`, `account/rateLimits/read`: `usedPercent`, `rateLimitReachedType` | Seen working, **experimental**; fall back to the next line |
| Both | Error text matching a quota pattern, taken from Job Radar's `QUOTA_PATTERN` | Fallback |

Show current usage per CLI in terminal settings and the desktop app. Whether Claude applies a separate pool to `claude -p` is **still unknown**: official pages don't mention one, secondary sources do. Treat the reported limits as the truth and record any difference.

## Redaction: regex only (D-08)
Before any LLM call, replace formatted values with tokens like `<EMAIL_1>`; restore them locally in the output. On by default; off via a setting. Port this set from `dev/spikes/regex_eval.py`, using the hush repo as the reference for validation:

`EMAIL`, `EMAIL_SPOKEN` ("x dot y at z dot com"), `API_KEY`, `URL_TOKEN`, `IBAN` (mod-97), `CN_ID` (checksum), `CN_MOBILE`, `SSN`, `CARD` (Luhn), `PHONE`.

Spoken names are **not** redacted; regex caught 0 of 7. The prompt tells the model to copy tokens exactly. On restore, an unknown or mangled token stays visible and is flagged, never guessed.

Keep `Tests/Fixtures/redaction/` with the invented transcripts and scores as a regression test. The patterns were written next to these fixtures, so add at least 10 new cases written independently (a fresh subagent prompt is fine) and report the score honestly.

## Done when
- [ ] With fake CLIs: tier mapping, no mixing, fallback only on a full limit, and API-key refusal are all tested.
- [ ] `--live`: Haiku and Sonnet return schema-valid JSON through the subscription; `apiKeySource` is none. Codex also passes.
- [ ] Old config with a Qianfan profile migrates, with its key entry gone and DeepSeek intact.
- [ ] Redaction: at least 95% on formatted values across old and new cases, no false positives on the set, and token restore works on Chinese text.
- [ ] A test proves transcript text never appears in a call with tools on.
