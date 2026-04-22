# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**MeetingCapture** — a macOS command-line tool (no GUI, that decision is final) that records a meeting, transcribes it locally with Whisper, and summarizes it with a user-configurable LLM. Full pipeline is local-first: audio capture and transcription never leave the machine; only the final transcript is sent to the user's chosen LLM endpoint.

Current state (v0.4): capture + transcribe + summarize all work. Interactive menu shell is the primary UX; flag-based invocation still works and is the scripting escape hatch.

## Build & run

Swift Package Manager, one external dep (WhisperKit). Requires macOS 14+.

```bash
swift build

# Interactive shell (primary UX):
.build/debug/MeetingCaptureCLI

# Flag path (scripting escape hatch, all still works):
.build/debug/MeetingCaptureCLI --duration 60 --transcribe --summarize --output /tmp/m.wav
.build/debug/MeetingCaptureCLI --transcribe-only /tmp/m.wav
.build/debug/MeetingCaptureCLI --summarize-only /tmp/m.txt
.build/debug/MeetingCaptureCLI --list      # enumerate SCShareableContent apps
```

Prefer running the compiled binary over `swift run`: TCC (Screen Recording permission) is keyed to the binary path; `swift run` can invalidate that.

No automated tests. Verification is manual: capture a WAV, inspect with `afinfo`, eyeball the `.txt` and `.md` outputs.

## Permissions

Two TCC entitlements required, both tied to the binary path:
- **Screen Recording** — System Settings → Privacy & Security → Screen Recording → add `.build/debug/MeetingCaptureCLI`. Symptom of missing grant: capture "succeeds" but produces a <0.5 s silent WAV; the code prints a hint.
- **Microphone** — prompted on first mic use. No prompt usually means silent denial; re-grant manually.

After rebuilds the path stays the same so grants persist.

## File-by-file

```
main.swift           flag parsing · shell bootstrap · flag-mode pipeline
Shell.swift          interactive menus (main + settings) · orchestrates the pipeline
Config.swift         persisted settings (JSON) · path/api-key helpers
AudioCapture.swift   SCShareableContent → SCContentFilter → SCStream; owns the WAV writer indirectly
MicCapture.swift     AVAudioEngine input tap · format conversion to 48 kHz stereo float32
MixingWriter.swift   sums mic + system samples, writes interleaved f32 WAV
CMSampleBuffer+PCM.swift  CMSampleBuffer → AVAudioPCMBuffer (handles non-interleaved ABL)
Transcribe.swift     WhisperKit wrapper · VAD chunking · timestamped .txt
Summarize.swift      POST to OpenAI-compatible /chat/completions · Kimi thinking-mode toggle
```

Defaults (all overridable via Settings menu or flags):
- Whisper: `openai_whisper-small.en`, VAD chunking on
- LLM: `kimi-k2.5` at `https://qianfan.baidubce.com/v2/coding` (Baidu Qianfan coding plan, OpenAI-compatible)
- Thinking mode: on, budget 32 000 tokens
- Output dir: `~/Documents/MeetingCapture`
- Duration: 30 min

API key: env var `QIANFAN_API_KEY` (or `LLM_API_KEY`), or `--llm-api-key`. **Never persisted.**

Settings JSON: `~/Library/Application Support/MeetingCapture/config.json`. Corrupt file → defaults + warning, never overwritten.

## Architecture gotchas

These are load-bearing and not obvious from reading a single file:

- **SCStream always needs video.** Audio-only isn't a thing in ScreenCaptureKit. `AudioCapture` sets a 2×2 / 1 fps dummy video stream so the video path costs nothing.
- **WAV can't store non-interleaved PCM**, and AVAudioFile silently rewrites the file header to interleaved — which then mismatches a non-interleaved write buffer and crashes. `CMSampleBuffer+PCM.swift` interleaves on the fly; `AudioCapture` opens AVAudioFile as interleaved f32. Do not try to "simplify" back to non-interleaved.
- **System audio drives the mix clock.** `MixingWriter.pushSystem()` consumes a matching number of mic frames from a FIFO per call. Mic FIFO is capped at 1 s to prevent unbounded growth if the mic is disconnected mid-recording.
- **WhisperKit default chunking drops cross-boundary speech.** The default `ChunkingStrategy` cuts at hard 30-second marks; Whisper's `noSpeechThreshold` (0.6) then classifies the cross-boundary uncertain audio as silence. `Transcribe.swift` explicitly passes `DecodingOptions(chunkingStrategy: .vad)` — do not remove this, it was the fix for a 22 s dropout.
- **Mid-recording stop uses stdin readability, not readLine.** `Shell.recordFlow()` installs `FileHandle.standardInput.readabilityHandler` before awaiting `capture.run()`, and removes it after. A blocking `readLine()` in a detached Task would leak the thread because Swift can't cancel blocking syscalls. Handler approach is clean.
- **`setbuf(stdout, nil)`** at the top of `main.swift` makes prompts and progress flush correctly and kept an early crash visible. Do not remove.
- **Sendable warnings exist** on `AudioCapture`'s Task/DispatchQueue captures. They're left as warnings deliberately; making the class an actor is a bigger refactor than we've invested in.

## Extending the tool

Likely next rounds: speaker diarization, custom prompt templates, chunked/streaming summarization (not needed for current transcript sizes — Kimi has 256 k context), a brittle-stdin fix via termios, Chinese-meeting polish (switch default to multilingual `small` and tune the prompt).

When working on the LLM side, check `memory/llm_provider.md` — the user has committed to Baidu Qianfan + Kimi-K2.5 as the default. Don't silently swap it.

When working on the shell, keep the "one keystroke to record" UX principle. If a feature needs a multi-prompt wizard, put it in the Settings menu.
