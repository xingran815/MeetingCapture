# MeetingCapture

A local-first macOS command-line tool that records your meeting audio (Zoom,
Teams, Google Meet, anything that plays through the speakers), transcribes it
on-device with [WhisperKit](https://github.com/argmaxinc/WhisperKit), and
summarizes the transcript with a bring-your-own LLM. Audio and transcripts
never leave your machine; only the final text is sent to the LLM endpoint you
configure.

Default LLM is [Kimi-K2.5](https://platform.moonshot.ai/) served through
[Baidu Qianfan](https://qianfan.cloud.baidu.com/)'s OpenAI-compatible
`/v2/coding` endpoint — swap in any other OpenAI-compatible endpoint if you
prefer.

---

## Requirements

| | |
|---|---|
| macOS | 14.0+ (WhisperKit floor) |
| Hardware | Apple Silicon recommended — Whisper runs on the Neural Engine. Intel works but is slow. |
| Toolchain | Xcode 15+ / Swift 5.9 |
| LLM | An API key for Baidu Qianfan Kimi-K2.5, **or** any other OpenAI-compatible `/chat/completions` endpoint |

---

## Build

```bash
git clone <this repo>
cd MeetingCapture
swift build
```

The binary lands at `.build/debug/MeetingCaptureCLI`. **Run the binary
directly** — not via `swift run`. macOS ties Screen Recording permission to
the binary path, and `swift run` invalidates that grant on every invocation.

---

## Permissions (TCC)

Two privacy entitlements are required, both pinned to the binary path. Grant
once and they persist across rebuilds (the path is stable).

1. **Screen Recording**
   System Settings → Privacy & Security → **Screen Recording** → click **+**
   and add `<repo>/.build/debug/MeetingCaptureCLI`.
   *Symptom of missing grant:* the capture "succeeds" but the output WAV is
   under 0.5 seconds and silent. The tool prints a hint when it detects this.

2. **Microphone**
   Prompted on first mic use. If you don't see a prompt, macOS has silently
   denied it — re-grant manually under Privacy & Security → **Microphone**.

---

## LLM setup

### Get a Kimi-K2.5 API key (default provider)

1. Sign up at [qianfan.cloud.baidu.com](https://qianfan.cloud.baidu.com/).
2. Subscribe to the coding plan (Kimi-K2.5 lives there).
3. Create an API key in the Qianfan console.

> Qianfan is a China-hosted service. If that's not workable for you, point
> the tool at any other OpenAI-compatible endpoint via **Settings → LLM base
> URL** in the interactive shell, or `--llm-base-url` on the command line.

### Store the key

In resolution order (first hit wins):

| Method | How | Notes |
|---|---|---|
| `--llm-api-key <key>` flag | On the command line | Visible in `ps`; use only for one-off scripting. |
| `QIANFAN_API_KEY` env var | `export QIANFAN_API_KEY=…` | Also accepts `LLM_API_KEY`. |
| macOS Keychain | Interactive shell → **Settings** → **LLM API key** | **Recommended.** Stored under service `MeetingCapture`, account `meeting_llm_api_key`. Never written to any config file. |

---

## Usage

### Interactive shell (primary UX)

```bash
.build/debug/MeetingCaptureCLI
```

Menu-driven: **Record → Transcribe → Summarize**. Press Enter during a
recording to stop early. All settings (Whisper model, LLM endpoint, output
directory, default duration, thinking-mode toggle) live under **Settings**.

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
| HTTP 401 from the LLM endpoint | API key unset or wrong. Re-enter under Settings → LLM API key. |
| Echo of the other person's voice in the recording | No software AEC yet — until v0.5 lands, use headphones to keep the partner's voice from bleeding into the mic. |

---

## Architecture

```
main.swift           flag parsing · shell bootstrap · flag-mode pipeline
Shell.swift          interactive menus · orchestrates record → transcribe → summarize
Menu.swift           arrow-key cbreak picker (+ piped-stdin fallback)
Config.swift         persisted settings (JSON at ~/Library/Application Support/MeetingCapture/)
Keychain.swift       LLM API key read/write via Security framework
AudioCapture.swift   ScreenCaptureKit stream (system audio)
MicCapture.swift     AVAudioEngine input tap with AEC
MixingWriter.swift   sums mic + system into one interleaved f32 WAV
CMSampleBuffer+PCM.swift   CMSampleBuffer → AVAudioPCMBuffer
Transcribe.swift     WhisperKit wrapper with VAD chunking
Summarize.swift      OpenAI-compatible POST to /chat/completions
```

---

## License

MIT. See [LICENSE](LICENSE).
