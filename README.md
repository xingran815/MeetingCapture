# MeetingCapture

A local-first macOS meeting helper. It records a call (Zoom, Teams, Webex, Google Meet in
Chrome or Safari, or any system audio) together with your microphone, transcribes it on your
Mac with [WhisperKit](https://github.com/argmaxinc/WhisperKit), and writes a
report: a self-contained HTML page plus Markdown and JSON.

- **Two ways to use it:** a terminal shell (`meetingcapture`) and a desktop app
  (`MeetingCapture.app`). Both read the same folder and settings.
- **Reports through your own subscription:** by default the report is written by
  the official `claude` or `codex` command-line tools, logged in with your own
  account. An API key (OpenAI, Anthropic, DeepSeek, Ollama, or any compatible
  endpoint) is optional.
- **Audio and transcription never leave the Mac.** Only transcript text, with
  formatted values such as emails and phone numbers replaced by tokens, goes to
  the model.

---

## Requirements

| | |
|---|---|
| macOS | 26 or later |
| Hardware | Apple Silicon. Whisper runs on the Neural Engine. |
| Toolchain | Xcode 26 or its Command Line Tools (Swift 6.2) |
| Reports | `claude` (Claude Code) or `codex` (Codex CLI), logged in with your subscription; or an API key for an API configuration |

---

## Recording consent

MeetingCapture records through the operating system. It does **not** tell other
participants, and the meeting app shows no "recording" badge.

- **Say that you're recording, and get consent, before you start.** Recording
  laws differ by place (all-party consent in some US states, GDPR in the EU, and
  others). Following them where everyone on the call is located is your job.
- macOS shows a purple indicator in the menu bar while audio is being captured.

---

## Install

### Terminal

```bash
git clone https://github.com/xingran815/MeetingCapture.git
cd MeetingCapture
./install.sh
```

`install.sh` builds a release binary, installs it to
`~/.local/bin/meetingcapture`, sets up the repo's git hooks, opens the Microphone
prompt, and walks you through the Screen Recording grant. It's safe to run again
after you pull: the path stays the same, so the grants stay valid.

To build without installing:

```bash
swift build
```

The binary is `.build/debug/MeetingCaptureCLI`. Run the binary itself, not
through `swift run`: macOS ties the Screen Recording grant to the binary's path.

### Desktop app

```bash
scripts/build-app.sh --install
```

This builds `.build/MeetingCapture.app` and copies it to `~/Applications`. The
app has its own permissions, which it asks for on first run, and it downloads
the Whisper model there with progress and Cancel. It is signed with your Apple
Development identity if the keychain has one, otherwise ad-hoc. An ad-hoc app
loses its permissions each time you rebuild it; it is meant for your own Mac,
not for handing to others.

### Permissions

| Permission | Where | If it's missing |
|---|---|---|
| Screen & System Audio Recording | System Settings → Privacy & Security → Screen & System Audio Recording. Add `~/.local/bin/meetingcapture` (or `.build/debug/MeetingCaptureCLI`); the app asks for itself | Capture "succeeds" with a silent file under half a second; the tool prints a hint |
| Microphone | Asked on first use | No prompt usually means it was denied; turn it on under Privacy & Security → Microphone |

---

## Set up reports

### Subscription CLIs (default)

Install and log in to at least one, with your own account:

```bash
claude --version
codex --version
```

| | Claude Code | Codex |
|---|---|---|
| Log in | run `claude` once and sign in | `codex login` (ChatGPT sign-in) |
| Cheap tier (topic and scenario) | `haiku` | `gpt-6-luna` |
| Normal tier (sections) | `sonnet` | `gpt-6.1-sol` |
| Frontier tier (review) | `opus` | `gpt-6-astra` |

The primary CLI runs every step of a report; the other one takes over only when
the primary's usage limit is full, and the report says so. Each CLI is capped at
200 calls a day by default. A CLI that would bill an API key instead of your
subscription is refused unless you set `"allowCLIAPIBilling": true` in
`config.json`. Details, and what each limit means:
[docs/llm-usage.md](docs/llm-usage.md).

Check that it works from the shell: **Settings → p Test CLI connection**, or in
the app: **Settings → Summaries → Test**.

### API configurations (optional)

In the shell, **Settings → 6 API configurations** keeps any number of named
configurations, each with its own provider, model, base URL, reasoning effort
and key:

| Preset | Base URL | Default model |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `deepseek-v4-flash` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| Anthropic | `https://api.anthropic.com/v1` | `claude-sonnet-4-6` |
| Ollama (local) | `http://localhost:11434/v1` | `llama3.1` |
| Custom | yours | yours |

Pick **Settings → c LLM route** to use the active API configuration instead of
the CLIs. Keys are found in this order: `--llm-api-key`, then `$LLM_API_KEY`,
then the key saved for that configuration in
`~/.config/MeetingCapture/llm_api_keys.json` (mode 0600, never in
`config.json`). On an API configuration every step uses its one model and there
is no concept search.

---

## Use it

### Terminal shell

```bash
meetingcapture
```

One key starts a recording. **Enter** stops it; **Space then Enter** pauses and
resumes. When it stops, the recording is transcribed and the report written.

| Key | Main menu |
|---|---|
| 1 | Record a meeting |
| 2 | Transcribe a recording |
| 3 | Summarize a `.txt` |
| 4 | Rename or merge speakers |
| 5 | Settings |
| 6 | Library: open a report, transcribe again, write the report again, rename, notes, group, show in Finder, delete to the Trash |
| 7 | Groups: reports that share context |

### Desktop app

Open **MeetingCapture** from `~/Applications`. Record from the toolbar (⌘R) or
the large button; pause with ⇧⌘P, stop with ⌘. . Recordings and reports are in
the sidebar. [docs/parity.md](docs/parity.md) lists where each feature lives in
the app and in the shell.

### Flags, for scripts

```bash
meetingcapture --help
meetingcapture --list
meetingcapture --duration 10 --transcribe --output /tmp/mc-demo.wav
meetingcapture --transcribe-only /tmp/mc-demo.m4a
cp Tests/Fixtures/live/meeting.txt /tmp/mc-sample.txt
meetingcapture --summarize-only /tmp/mc-sample.txt
meetingcapture --summarize-only /tmp/mc-sample.txt --scenario meeting --llm-cli codex
meetingcapture --audio-cleanup
```

`--list` shows the apps ScreenCaptureKit can see. The sample transcript is
invented; a report is written beside it. `--audio-cleanup` lists old WAV
recordings and converts or deletes only after you answer.

---

## What you get

Recordings go to `~/Documents/MeetingCapture/` unless you change it
(**Settings → 3**). In flag mode, a recording goes to the current folder
unless `--output` names another, and retention doesn't cover it there. For a recording named `<base>`:

| File | What |
|---|---|
| `<base>.m4a` | The raw recording, two tracks: your mic and the system audio. Kept as WAV while recording, converted once the M4A is proven good |
| `<base>_clean.m4a` | The same, with the speaker echo taken off your mic track, for listening |
| `<base>.txt` | The transcript: `[hh:mm:ss] You: …`, `Speaker 1: …` |
| `<yyyyMMdd_HHmmss>_<topic>.html` | The report: one page, works offline, light and dark, searchable transcript |
| `<base>.md`, `<base>.report.json` | The same report as Markdown and as data |
| `<base>.edits.json`, `<base>.notes.md` | Your title, edits and notes. A re-run never overwrites them |
| `<base>.mcmeta.json` | Which files belong to this recording, for retention and delete |

### Reports

Each transcript is classified as a meeting, therapy session, interview,
one-on-one, lecture or general conversation, and filled from that scenario's
template. `--scenario <name>` skips the guess. Templates are JSON; a file in
`~/.config/MeetingCapture/scenarios/` adds one or replaces a built-in. A
frontier model reviews the draft against the transcript; if the review fails,
the report says "Not reviewed".

### Notebook

A report is yours to change: rename it, keep notes beside it, edit its text (in
the app), or move the recording to the Trash. Notes go to the model only if you
turn that on for that report. Delete moves only the files the recording lists,
to the Trash, never for good. A report's notes, once that switch is on, also go
to the model with every later report in its group (see Groups).

### Groups

Put related reports in a group (a weekly one-on-one, a course). A new report in
a group gets the earlier reports in it as context: their titles, sections and
items, plus an earlier report's notes when that report's notes switch is on;
never their transcripts or quotes. Up to 24,000 characters, newest first. The
context is redacted with the transcript unless you turn the group's **Redact
the context** switch off. A fact that comes only from an earlier report is marked **From an earlier
report, not said in this recording**, so you can tell the two apart. Groups
live in `groups.json` in the output folder.

---

## Privacy

| Step | Where it runs | What leaves the Mac |
|---|---|---|
| Recording | Your Mac | Nothing |
| Echo removal, transcription, speaker turns | Your Mac (WhisperKit, SpeakerKit) | Nothing. Models are downloaded once from Hugging Face |
| Report | `claude` or `codex` with your login, or your API configuration | The transcript text, redacted; your notes if you turned that on; a group's earlier reports and their allowed notes, redacted unless the group's switch is off |
| Concept search | The CLI's web search | Concept names only, never transcript text. The model is told to keep them generic and renamed speakers' names are filtered out, but another name can slip into one |

**Redaction** replaces formatted values before any model call: emails (also
spoken ones), API keys, tokens in URLs, IBANs, card numbers, phone numbers, US
SSNs, Chinese ID and mobile numbers. They're put back on your Mac afterwards.
**It does not catch names**, addresses, or anything said without a fixed
format: assume the provider sees those. Turn redaction off with **Settings → x**
or `--no-redact`.

**Retention:** audio is deleted 30 days after its transcript was saved
(**Settings → d**; 0 keeps it forever). Only the files a recording's
`.mcmeta.json` lists are deleted, and never audio without a transcript.
Transcripts and reports are kept.

The tool doesn't log keys, tokens or transcript text. See
[SECURITY.md](SECURITY.md).

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| The recording is silent and under half a second | Screen & System Audio Recording isn't granted to this binary's path |
| No microphone prompt | macOS denied it quietly; turn it on under Privacy & Security → Microphone |
| `No display found` | ScreenCaptureKit needs a display; it doesn't work over SSH or headless |
| The meeting app isn't detected | Run `meetingcapture --list`. Use **Settings → s Audio source → All system audio** or `--all-audio` |
| "No subscription CLI is ready" | `claude` or `codex` isn't on `PATH` or isn't logged in. Run Test CLI connection |
| A CLI is refused as "API billing" | It's logged in with an API key, not a subscription. Log in with your account, or set `allowCLIAPIBilling` in `config.json` |
| Both CLIs are "usage full" | The daily cap or the subscription limit is reached. The transcript is kept; write the report again after the reset time shown |
| The report says "Not reviewed" | The review step failed; the draft is shown as it was |
| The app lost its permissions after a rebuild | It's signed ad-hoc. Grant them again, or build with an Apple Development identity |
| You can still hear the other side faintly on your track | Echo removal works after the call and lowers it a lot, but not to zero. Headphones avoid it. `--no-aec` turns removal off |

---

## For developers

```bash
scripts/setup.sh
scripts/check.sh --unit
```

`CLAUDE.md` describes the code, its gotchas, and the development rules;
`scripts/check.sh --full` is the complete local check. Settings live in
`~/.config/MeetingCapture/config.json`.

## License

MIT. See [LICENSE](LICENSE).
