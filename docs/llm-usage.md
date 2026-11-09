# How MeetingCapture uses language models

## Personal use

MeetingCapture runs the **official, unmodified** `claude` and `codex` command-line
tools, logged in with **your own** account. It never reads, stores or forwards
their login tokens, and it doesn't proxy them. Use your own login on your own Mac;
anyone else who uses MeetingCapture logs in with their own account. Sharing one
subscription between people is not what this is for, and the providers' terms
apply to every call.

## Routes

| Route | When | Who pays |
|---|---|---|
| Subscription CLIs (default) | `config.llmRoute` is `subscription` and a CLI is ready | Your Claude or ChatGPT plan |
| API configuration | You chose it under **Settings → c LLM route**, used `--llm-profile` or another `--llm-*` flag, or no CLI is ready and an API configuration exists | The API account behind that key |

Setting `MEETINGCAPTURE_CLI_ONLY=1` refuses the API route, the `--llm-*`
overrides, and the fallback to an API configuration, so nothing can bill an API
key.

## One report, step by step

| Step | Tier | Claude | Codex | What it sees |
|---|---|---|---|---|
| Topic and scenario | Cheap | `haiku` | `gpt-6-luna` | The redacted transcript |
| Sections | Normal | `sonnet` | `gpt-6.1-sol` | The redacted transcript, your notes if allowed, a group's earlier reports |
| Concept search | Normal, web search on | `sonnet` | `gpt-6.1-sol` | Concept names only; meant to be generic, but only renamed speakers' names are filtered |
| Review | Frontier | `opus` | `gpt-6-astra` | The draft, the redacted transcript, a group's earlier reports |

A typical report is 3 to 5 calls; a malformed reply gets one retry.
`--scenario` skips the first step. The model names are settings, because they
change. Tools stay off for every call that holds transcript text; the search is
a separate call.

The **primary CLI** (Settings, default `claude`) runs every step. The other CLI
takes over the remaining steps **only when the primary's usage is full**, never
for other errors, and the report says so. Tiers are never mixed across CLIs
within one step.

## What each limit means

| Limit | Where it comes from | What happens when it's reached |
|---|---|---|
| **Daily call cap** | MeetingCapture's own count, 200 calls per CLI per local day by default (**Settings → l**). Every started process counts, including failures, retries and searches. Kept in `~/.config/MeetingCapture/usage.json`, shared by the app and the shell | That CLI counts as full; the other one takes over |
| **Subscription limit** | What the CLI reports: Claude's `rate_limit_event` (status, use per window, reset time), and Codex's `account/rateLimits/read` (experimental). An error that reads like a quota message counts too | That CLI counts as full until the reported reset |
| **Both full** | Either of the above on both CLIs | The run stops. The transcript and any finished steps are kept, and the message says when the count and the limit reset. It never moves to an API configuration on its own, because that would start billing |

The shell's Settings and the app's **Settings → Summaries** show today's count
and the last reported limits for each CLI.

## API billing guard

A CLI logged in with an API key (`apiKeySource` other than none, or `codex login
status` not saying ChatGPT) would bill that key. MeetingCapture refuses it unless
`"allowCLIAPIBilling": true` is in `config.json`. The CLIs start with an
allow-listed environment (`HOME`, `PATH`, `USER`, `TMPDIR`), so a stray
`ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in your shell isn't passed on.

## Checks that spend usage

Only these do, and each checks the daily cap first:

```bash
scripts/check.sh --live
scripts/quality-compare.sh --redaction
scripts/live-group-report.sh
```

Every other test uses fake CLIs on `PATH`.
