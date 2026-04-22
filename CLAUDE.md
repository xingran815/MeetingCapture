# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Spike-quality CLI (`MeetingCaptureCLI`) that proves ScreenCaptureKit can capture per-app audio from Zoom / Teams / Webex / browsers and write it to a WAV file. This is step one of a larger plan: a local-first, open-source macOS meeting-summary app (Whisper transcription + user-configurable LLM summarisation). Everything else in the plan depends on this capture path working, so the CLI exists to de-risk it.

## Build & run

Swift Package Manager, no external dependencies:

```bash
swift build
.build/debug/MeetingCaptureCLI --list                                    # enumerate apps/displays
.build/debug/MeetingCaptureCLI --duration 30 --output zoom.wav           # per-app capture (auto-detects Zoom/Teams/…)
.build/debug/MeetingCaptureCLI --all-audio --duration 10 --output sys.wav # whole-display fallback
```

Prefer running the compiled binary over `swift run`: TCC (Screen Recording permission) is keyed to the executable path, and `swift run` occasionally rebuilds into a new hash.

There are no tests. Verification = capture a WAV and inspect it (`afinfo file.wav`, `ffprobe`, open in QuickTime).

## Permission gotcha

ScreenCaptureKit requires **Screen Recording** permission on whichever binary actually runs. For `.build/debug/MeetingCaptureCLI`, add that path in System Settings → Privacy & Security → Screen Recording, and quit/relaunch the shell. Symptom of missing permission: capture succeeds but produces a <0.5s WAV with silence (no error is raised). The code prints a hint when it detects this.

## Architecture

Three files, tight pipeline:

```
main.swift           arg parsing → Task { AudioCapture().run(...) } → RunLoop.main.run()
AudioCapture.swift   SCShareableContent → SCContentFilter → SCStream → SCStreamOutput → AVAudioFile
CMSampleBuffer+PCM.swift   CMSampleBuffer → AVAudioPCMBuffer (handles non-interleaved ABL)
```

Key design points that aren't obvious from reading any single file:

- **SCStream always needs video.** Audio-only capture isn't a thing in ScreenCaptureKit. `AudioCapture.run()` sets a 2×2 / 1 fps dummy video stream so the video path costs nothing.
- **Source format vs. file format differ.** SCStream delivers float32 **non-interleaved** 48kHz stereo. WAV cannot store non-interleaved PCM — AVAudioFile silently rewrites the file header to interleaved, which would mismatch a non-interleaved write buffer and crash. So `CMSampleBuffer+PCM.swift` interleaves on the fly into an interleaved `AVAudioPCMBuffer`, and `AudioCapture` opens `AVAudioFile` as interleaved float32. The README's "non-interleaved WAV" claim is outdated — the code is interleaved end-to-end.
- **Per-app filter first, all-audio fallback.** `run()` walks a hard-coded bundle-ID candidate list (Zoom, Teams, Webex, Chrome, Safari) and builds `SCContentFilter(display:including:exceptingWindows:)` for the first match. If none are running it prints a warning and falls back to the display-wide filter. `--all-audio` forces the fallback.
- **Stop path via continuation.** `run()` suspends on a `CheckedContinuation` that `stopRecording` resumes. The timer-triggered stop uses `DispatchQueue.main.asyncAfter`; Ctrl+C is not wired, so short durations are the only clean exit.
- **Debug prints go to stdout with `setbuf(stdout, nil)`** in `main.swift`. This was added because a crash earlier dropped all buffered prints, making the failure invisible. Keep the unbuffered setup when debugging — remove only for "release" polish.

## When extending this

The stated next steps (see README) are: whisper.cpp integration → real-time chunked transcription → speaker diarisation → OpenAI-compatible LLM summary. If you're plumbing in Whisper, decode the 48kHz/stereo/float32 WAV; Whisper wants 16kHz/mono/float32, so resample before feeding samples in (don't change the capture-side format — its fidelity is a feature).

The capture class is `final class AudioCapture: NSObject` with Swift 6 concurrency warnings around `self` capture in the Task/DispatchQueue closures. Those are intentionally left as warnings for the spike; a real app should make this an actor or an @MainActor class.
