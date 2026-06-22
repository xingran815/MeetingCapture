# MeetingCapture

A local-first macOS command-line tool that records your meeting audio (Zoom,
Teams, Google Meet, anything that plays through the speakers), transcribes it
on-device with [WhisperKit](https://github.com/argmaxinc/WhisperKit), and
summarizes the transcript with a bring-your-own LLM. Audio and transcripts
never leave your machine; only the final text is sent to the LLM endpoint you
configure.

Pick your LLM provider in **Settings → LLM provider**: presets for OpenAI, a
local [Ollama](https://ollama.com/), or [Kimi-K2.5](https://platform.moonshot.ai/)
via [Baidu Qianfan](https://qianfan.cloud.baidu.com/) (the default), plus a
**Custom** option for any other OpenAI-compatible `/chat/completions` endpoint.
A built-in **Test connection** check verifies the endpoint, key, and model
before you rely on them.

---

## Requirements

| | |
|---|---|
| macOS | 14.0+ (WhisperKit floor) |
| Hardware | Apple Silicon recommended — Whisper runs on the Neural Engine. Intel works but is slow. |
| Toolchain | Xcode 15+ / Swift 5.9 |
| LLM | An API key for any OpenAI-compatible `/chat/completions` provider (OpenAI, Qianfan/Kimi, a local Ollama, etc.) |

---

## Recording disclosure & consent

This tool captures audio via OS-level taps (system audio + your local mic). It
does **not** notify other meeting participants — Zoom, Teams, and Meet only
display a "recording" indicator when *their own* record button is used. Other
participants will not know you're recording unless you tell them.

- **Disclose verbally before recording.** Consent-to-record laws vary by
  jurisdiction (US two-party-consent states, GDPR in the EU, etc.). It is your
  responsibility to comply with the law where you and the other participants
  are located.
- macOS displays a **purple dot** in the menu bar while Screen Recording is
  active. Anyone watching your screen-share can see it.

---

## Quick install

```bash
git clone <this repo>
cd MeetingCapture
./install.sh
```

Builds release, installs to `~/.local/bin/meetingcapture`, triggers the
Microphone prompt, and walks you through the Screen Recording grant. Safe to
re-run after rebuilds — TCC grants stay valid because the install path is
stable.

### Manual build (fallback)

```bash
swift build -c release
```

The binary lands at `.build/release/MeetingCaptureCLI`. **Run the binary
directly** — not via `swift run`. macOS ties Screen Recording permission to
the binary path, and `swift run` invalidates that grant on every invocation.

---

## Permissions (TCC)

`./install.sh` handles both grants. If you built manually, do them by hand —
both are pinned to the binary path and persist across rebuilds.

1. **Screen Recording**
   System Settings → Privacy & Security → **Screen Recording** → click **+**
   and add the binary path (`~/.local/bin/meetingcapture` if you used the
   installer, otherwise `<repo>/.build/release/MeetingCaptureCLI`).
   *Symptom of missing grant:* the capture "succeeds" but the output WAV is
   under 0.5 seconds and silent. The tool prints a hint when it detects this.

2. **Microphone**
   Prompted on first mic use. If you don't see a prompt, macOS has silently
   denied it — re-grant manually under Privacy & Security → **Microphone**.

---

## LLM setup

### Choose a provider

Open the interactive shell → **Settings → LLM provider** and pick a preset:

| Preset | Base URL | Default model |
|---|---|---|
| **Qianfan / Kimi** (default) | `https://qianfan.baidubce.com/v2/coding` | `kimi-k2.5` |
| **OpenAI** | `https://api.openai.com/v1` | `gpt-4o-mini` |
| **Ollama (local)** | `http://localhost:11434/v1` | `llama3.1` |
| **Custom…** | *(you supply)* | *(you supply)* |

Selecting a preset pre-fills the base URL and model; both stay editable under
**LLM model** / **LLM base URL** (or via `--llm-model` / `--llm-base-url`).
**Custom…** prompts for a name (e.g. "DeepSeek" — DeepSeek, Together, Groq, and
most hosted LLMs expose an OpenAI-compatible endpoint), a base URL, and a model.
Use **Settings → Test connection** to verify the endpoint, key, and model with a
one-token request before recording.

> The default, Qianfan, is a China-hosted service. To use it, sign up at
> [qianfan.cloud.baidu.com](https://qianfan.cloud.baidu.com/), subscribe to the
> coding plan (Kimi-K2.5 lives there), and create an API key in the console.

### Store the key

In resolution order (first hit wins):

| Method | How | Notes |
|---|---|---|
| `--llm-api-key <key>` flag | On the command line | Visible in `ps`; use only for one-off scripting. |
| `LLM_API_KEY` env var | `export LLM_API_KEY=…` | Legacy `QIANFAN_API_KEY` also accepted. |
| Key file | Interactive shell → **Settings** → **LLM API key** | **Recommended.** Written to `~/.config/MeetingCapture/llm_api_key` (mode `0600`) — kept out of `config.json`. A key from an older version's Keychain entry is migrated here automatically. |

---

## Usage

### Interactive shell (primary UX)

```bash
.build/debug/MeetingCaptureCLI
```

Menu-driven: **Record → Transcribe → Summarize**. Press Enter during a
recording to stop early. All settings (Whisper model, LLM endpoint, output
directory, default duration, LLM provider, reasoning-mode toggle) live under
**Settings**.

### Flag mode (scripting)

```bash
# Full pipeline: record 60 s, transcribe, summarize
.build/debug/MeetingCaptureCLI --duration 60 --transcribe --summarize --output /tmp/m.wav

# Transcribe or summarize an existing file
.build/debug/MeetingCaptureCLI --transcribe-only /tmp/m.wav
.build/debug/MeetingCaptureCLI --summarize-only /tmp/m.txt

# Sanity-check: list what ScreenCaptureKit can see
.build/debug/MeetingCaptureCLI --list
```

Outputs default to `~/Documents/MeetingCapture/` — a `.wav`, a timestamped
`.txt` transcript, and a Markdown `.md` summary per session.

---

## Privacy

- **Audio** is captured and mixed locally into a WAV file on your disk. It is
  never uploaded anywhere.
- **Transcription** runs entirely on-device via WhisperKit (CoreML). The
  Whisper model is fetched from Hugging Face on first use and cached locally;
  subsequent runs are offline.
- **Summarization** is the only step that leaves the machine: the transcript
  text is POSTed to whichever LLM endpoint you configured. Choose your
  provider accordingly.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| WAV is 0 s / silent | Screen Recording permission missing or attached to the wrong binary path. Re-grant for `.build/debug/MeetingCaptureCLI`. |
| No microphone prompt appeared | macOS silently denied. Grant manually under Privacy & Security → Microphone. |
| `No display found` | ScreenCaptureKit needs an attached display. It does not work over SSH or on headless hardware. |
| Zoom not detected | Run `--list`; look for `us.zoom.xos`. If absent, Zoom isn't running. Falls back to `--all-audio`. |
| HTTP 401 from the LLM endpoint | API key unset or wrong. Re-enter under Settings → LLM API key, then Settings → Test connection. |
| Echo of the other person's voice in the recording | Software AEC is on by default (Speex, 150 ms tail). If still audible, the mic may be too close to speakers or volume is very high — try headphones for critical recordings. Disable with `--no-aec` or Settings → AEC if you prefer. |

---

## Architecture

```
main.swift           flag parsing · shell bootstrap · flag-mode pipeline
Shell.swift          interactive menus · orchestrates record → transcribe → summarize
Menu.swift           arrow-key cbreak picker (+ piped-stdin fallback)
Config.swift         persisted settings (JSON at ~/.config/MeetingCapture/)
LLMProvider.swift    catalog of LLM provider presets (OpenAI, Ollama, Qianfan/Kimi, custom)
APIKeyStore.swift    LLM API key file (~/.config/MeetingCapture/llm_api_key, mode 0600)
Keychain.swift       legacy keychain read path (migrated to APIKeyStore on first use)
AudioCapture.swift   ScreenCaptureKit stream (system audio)
MicCapture.swift     AVAudioEngine input tap (mono, 48 kHz)
EchoCanceller.swift  Speex-based acoustic echo cancellation (software AEC)
MixingWriter.swift   sums mic + system into one interleaved f32 WAV
CMSampleBuffer+PCM.swift   CMSampleBuffer → AVAudioPCMBuffer
Transcribe.swift     WhisperKit wrapper with VAD chunking
Summarize.swift      OpenAI-compatible POST to /chat/completions
```

---

## License

MIT. See [LICENSE](LICENSE).
