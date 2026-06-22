# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**MeetingCapture** — a macOS command-line tool (no GUI, that decision is final) that records a meeting, transcribes it locally with Whisper, and summarizes it with a user-configurable LLM. Full pipeline is local-first: audio capture and transcription never leave the machine; only the final transcript is sent to the user's chosen LLM endpoint.

Current state (v0.6): capture + transcribe + summarize all work. Software AEC via vendored speexdsp. Indefinite-length recordings with 30-min chunking for fault tolerance. Interactive menu shell is the primary UX; flag-based invocation still works and is the scripting escape hatch.

## Build & run

Swift Package Manager, one external dep (WhisperKit). Requires macOS 14+.

End-user / fresh-machine path: `./install.sh` builds release, installs to `~/.local/bin/meetingcapture`, triggers the mic prompt via the hidden `--permission-probe` flag, and walks the user through the Screen Recording grant. Idempotent.

Dev loop:

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
Menu.swift           termios cbreak list picker: Menu.pick (one-shot) + Menu.run (stays open, redraws in place)
MeetingApps.swift    catalog of conferencing apps for SCStream audio auto-detection
LLMProvider.swift    catalog of LLM provider presets (qianfan/openai/ollama/custom) · supportsReasoning flag
Config.swift         persisted settings (JSON) · path/api-key helpers · legacy-path + legacy-key migration
AudioCapture.swift   SCShareableContent → SCContentFilter → SCStream; owns the WAV writer indirectly
MicCapture.swift     AVAudioEngine input tap · format conversion to 48 kHz mono
EchoCanceller.swift  Speex-based acoustic echo cancellation (software AEC)
MixingWriter.swift   sums mic + system, downmixes to mono, writes int16 WAV; 30-min chunk rotation; pause/resume
CMSampleBuffer+PCM.swift  CMSampleBuffer → AVAudioPCMBuffer (handles non-interleaved ABL)
Transcribe.swift     WhisperKit wrapper · VAD chunking · timestamped .txt
Summarize.swift      POST to OpenAI-compatible /chat/completions · provider-specific reasoning toggle · ping() connectivity check
APIKeyStore.swift    file-based LLM API key (~/.config/MeetingCapture/llm_api_key, mode 0600)
Keychain.swift       LEGACY API-key read/delete only — new keys go to APIKeyStore; kept for migration
Sources/Speexdsp/    Vendored xiph/speexdsp (BSD-3) — MDF echo canceller + preprocessor
install.sh           build (release) → install to ~/.local/bin → trigger TCC prompts
```

Defaults (all overridable via Settings menu or flags):
- Whisper: `openai_whisper-small.en`, VAD chunking on
- LLM: provider preset `qianfan` (`kimi-k2.5` at `https://qianfan.baidubce.com/v2/coding`, Baidu Qianfan coding plan). Other presets: `openai`, `ollama`, `custom` — see `LLMProvider.catalog`. Selecting a preset prefills `llmBaseURL`/`llmModel`; both stay editable. The `custom` provider is user-nameable (`config.llmCustomName`, surfaced via `config.llmProviderDisplayName`). Settings → Test connection runs a one-token `/chat/completions` ping (`Summarizer.ping`).
- Reasoning mode: off (budget 32 000 tokens when enabled). Provider-specific — only sent (and only offered in Settings) when the selected provider's `supportsReasoning` is true (currently just Qianfan/Kimi, via the Kimi-style `thinking` body param). `config.reasoningEnabled` / `reasoningBudgetTokens` (renamed from `kimiThinking*`; old keys still decoded for migration).
- Output dir: `~/Documents/MeetingCapture`
- Duration: 480 min (8h safety cap; Enter to stop, Space+Enter to pause/resume; recordings chunked every 30 min)
- WAV output: interleaved mono int16 @ 48 kHz (~5.6 MB/min)
- Audio source: meeting-app auto-detect on (all 5 apps enabled). Settings → Audio source has an explicit "All system audio" toggle (`config.captureAllAudio`) that bypasses auto-detection; equivalent to the `--all-audio` flag.

API key resolution (first hit wins): `--llm-api-key` flag → `LLM_API_KEY` env → `QIANFAN_API_KEY` env (legacy) → `APIKeyStore` file (`~/.config/MeetingCapture/llm_api_key`, mode 0600) → macOS Keychain (legacy). A key found only in the Keychain is copied into the file on read (one-time migration). The key file is set/cleared from Settings → LLM API key; it is kept OUT of `config.json` so the JSON stays safe to share. Note: a plaintext 0600 file is the user's explicit choice over the Keychain.

Settings JSON: `~/.config/MeetingCapture/config.json` (moved from `~/Library/Application Support/MeetingCapture/`; the old path is read once and migrated forward on first load, non-destructively). Corrupt file → defaults + warning, never overwritten.

## Architecture gotchas

These are load-bearing and not obvious from reading a single file:

- **SCStream always needs video.** Audio-only isn't a thing in ScreenCaptureKit. `AudioCapture` sets a 2×2 / 1 fps dummy video stream so the video path costs nothing.
- **WAV can't store non-interleaved PCM**, and AVAudioFile silently rewrites the file header to interleaved — which then mismatches a non-interleaved write buffer and crashes. `CMSampleBuffer+PCM.swift` interleaves on the fly; `MixingWriter` opens AVAudioFile as interleaved mono int16. Do not try to "simplify" back to non-interleaved. Internal mixing is float32; the float→int16 clamp + scale happens at the write boundary in `pushSystem()`.
- **Pause drops frames; it does not splice silence.** `MixingWriter.togglePause()` early-returns from `pushSystem`/`pushMic` while paused, and clears the mic FIFO on pause-entry to avoid a splice on resume. Audio time stays contiguous in the WAV — wall-clock pause gap simply doesn't exist in the file. Transcript timestamps reflect audio time.
- **System audio drives the mix clock.** `MixingWriter.pushSystem()` consumes a matching number of mic frames from a FIFO per call. Mic FIFO is capped at 1 s to prevent unbounded growth if the mic is disconnected mid-recording.
- **Long recordings are chunked.** `MixingWriter` rotates to a new WAV file every 30 minutes (`meeting.wav`, `meeting_part2.wav`, ...). This provides fault tolerance — if a crash occurs at minute 45, the first chunk is preserved. `Transcribe.transcribe(wavPaths:)` concatenates chunks with adjusted timestamps.
- **WhisperKit default chunking drops cross-boundary speech.** The default `ChunkingStrategy` cuts at hard 30-second marks; Whisper's `noSpeechThreshold` (0.6) then classifies the cross-boundary uncertain audio as silence. `Transcribe.swift` explicitly passes `DecodingOptions(chunkingStrategy: .vad)` — do not remove this, it was the fix for a 22 s dropout.
- **Mid-recording stop/pause uses stdin readability, not readLine.** `Shell.recordFlow()` installs `FileHandle.standardInput.readabilityHandler` before awaiting `capture.run()`, and removes it after. The handler dispatches on input: bare `" "` (after stripping CR/LF) → `pauseToggle()`, anything else → `manualStop()`. A blocking `readLine()` in a detached Task would leak the thread because Swift can't cancel blocking syscalls. Handler approach is clean. **Caveat:** the handler only fires on a real TTY — when stdin is piped (testing), libc fully buffers stdin and the FileHandle dispatch source never sees subsequent bytes. Pause/stop are not reachable from piped tests; verify via interactive tty.
- **`setbuf(stdout, nil)`** at the top of `main.swift` makes prompts and progress flush correctly and kept an early crash visible. Do not remove.
- **Sendable warnings exist** on `AudioCapture`'s Task/DispatchQueue captures. They're left as warnings deliberately; making the class an actor is a bigger refactor than we've invested in.
- **Do not enable Apple's Voice-Processing I/O on the mic input.** `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` was tried (commit `fc39ed2`) to cancel the speaker→mic echo. It works as an AEC, but the API also switches the system audio HAL into "voice chat" mode — that ducks output (overriding user volume) and puts the mic into an exclusive voice-processing path. Any concurrent VoIP app (Zoom, Meet, Teams) that's also using VPIO is then unable to capture the mic, and its playback gets duck-attenuated. Recording becomes unusable in real meetings. **The fix is implemented:** software AEC via vendored `speexdsp` running in user-space against our own mic and SCStream buffers — that path doesn't claim the HAL session. Disable with `--no-aec` or Settings → AEC if needed.

## Extending the tool

Likely next rounds: speaker diarization, custom prompt templates, chunked/streaming summarization (not needed for current transcript sizes — Kimi has 256 k context), a brittle-stdin fix via termios, Chinese-meeting polish (switch default to multilingual `small` and tune the prompt).

When working on the LLM side, check `memory/llm_provider.md` — the user has committed to Baidu Qianfan + Kimi-K2.5 as the default. Don't silently swap it.

When working on the shell, keep the "one keystroke to record" UX principle. If a feature needs a multi-prompt wizard, put it in the Settings menu.

Settings and the audio-source picker use `Menu.run`, not `Menu.pick`: it stays open and redraws the menu **in place** (clears its block, runs the per-selection handler, re-renders) so changing a setting never prints a fresh stacked copy. Consequence: pure toggles must NOT print confirmations (the `[bracketed]` value already updates on redraw); rely on the menu's own redraw for feedback. In-place redraw only happens on a real TTY — piped stdin falls back to a reprinted numbered list.

The Settings menu is grouped with dimmed `MenuItem.separator(...)` header rows (Capture & transcription / LLM / Audio). Because separators shift row indices, the `Menu.run` handler dispatches on `buildItems()[i].key` (the item's shortcut char), **not** the positional index — so you can reorder rows or add/remove separators without renumbering the `switch`. `Menu.run` only ever calls the handler with the index of an *enabled* row, so separators are never dispatched. Shortcut keys must avoid `j`/`k`/`q`/`b` (reserved by the picker for navigation/back/quit).
