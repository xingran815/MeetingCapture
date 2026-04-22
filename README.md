# MeetingCaptureCLI

Minimal spike to verify that **ScreenCaptureKit can capture Zoom (and other
meeting app) audio** and write it to a WAV file.  This is the highest-risk
part of a full meeting-summary macOS app — everything else (Whisper, LLM
summarisation) is straightforward once audio capture is proven.

---

## Requirements

| | |
|---|---|
| macOS | 13.0+ (Ventura) |
| Xcode | 15+ (Swift 5.9) |
| Permission | **Screen Recording** granted to your terminal or binary |

---

## Permission setup  ⚠️  (do this first)

ScreenCaptureKit requires the **Screen Recording** privacy entitlement.
For a CLI tool the permission is attached to whichever process runs it —
Terminal.app if you use `swift run`, or the compiled binary itself.

1. **System Settings → Privacy & Security → Screen Recording**
2. Click **+**, navigate to `/Applications/Utilities/Terminal.app`, add it.
3. **Quit and relaunch Terminal** (the OS won't see the new permission until
   the process restarts).

> If you compile to a binary and run it directly (`./MeetingCaptureCLI`),
> you need to add **that binary's path** instead of Terminal.

---

## Quick start

```bash
# Clone / copy the project, then:
cd MeetingCaptureCLI

# 1. List all running apps (sanity check)
swift run MeetingCaptureCLI --list

# 2. Capture 30 s of Zoom audio  (start a Zoom call first)
swift run MeetingCaptureCLI --duration 30 --output zoom_test.wav

# 3. No Zoom?  Capture all system audio instead  (play a YouTube video)
swift run MeetingCaptureCLI --all-audio --duration 10 --output system_test.wav

# 4. Verify the output
ffprobe zoom_test.wav
# or open in Audacity / QuickTime Player
```

---

## What you should see

```
╔════════════════════════════════════════════╗
║   MeetingCaptureCLI  ·  v0.1 spike         ║
║   ScreenCaptureKit audio capture test      ║
╚════════════════════════════════════════════╝

Enumerating screen content…
Found Zoom: us.zoom.xos
┌──────────────────────────────────────────┐
│  Capture target : Zoom                   │
│  Duration       : 30s                    │
│  Format         : 48 kHz · stereo · f32  │
│  Output         : zoom_test.wav          │
└──────────────────────────────────────────┘
🔴 Recording…  (Ctrl+C to stop early)

  [████████░░░░░░░░░░░░░░░░░░░░░░]   5.0s / 30s
  [████████████████░░░░░░░░░░░░░░]  10.0s / 30s
  ...

──────────────────────────────────────────
✅  Done!
   Captured  : 30.00s  (1440000 samples)
   Saved to  : /path/to/zoom_test.wav
   File size : 5625.0 KB
```

---

## Troubleshooting

### Capture is 0.00 s or file is empty
Screen Recording permission is missing.  See **Permission setup** above.
After granting the permission you **must restart Terminal**.

### Zoom is not detected
Run `--list` and look for `us.zoom.xos` in the output.  If it is absent,
Zoom is not running.  Start a meeting (or the Zoom client) and retry.
You can use `--all-audio` as a fallback — play any audio on the Mac to
verify the pipeline works end-to-end.

### "No display found"
Run the tool on the Mac directly, not inside an SSH session or a headless
environment.  ScreenCaptureKit requires an attached display.

### Permission prompt never appeared
Some macOS versions don't show a prompt; they silently deny and return an
empty stream.  Go to System Settings and add the binary manually.

---

## Architecture notes

```
SCShareableContent          ← enumerate apps/displays
    │
SCContentFilter             ← "only audio from us.zoom.xos"
    │
SCStream (audio + 2×2 video)← smallest possible video to satisfy API
    │
SCStreamOutput.didOutput    ← CMSampleBuffer (f32, non-interleaved, 48 kHz)
    │
CMSampleBuffer+PCM.swift    ← safe ABL extraction → AVAudioPCMBuffer
    │
AVAudioFile (WAV)           ← WAVE_FORMAT_IEEE_FLOAT, 48 kHz, stereo
```

**Why non-interleaved float32 WAV?**
SCStream delivers exactly that format, so zero conversion cost and zero
precision loss.  It's valid WAV (IEEE float extension) — ffmpeg, Audacity,
Logic, and most DAWs read it natively.

**Why minimal 2×2 video?**
SCStream requires a display even for audio-only capture.  Setting
`minimumFrameInterval = 1 fps` and `2×2` resolution means the video path
costs essentially nothing.

---

## Next steps (once capture is verified)

1. **Pipe to Whisper** — feed the WAV into `whisper.cpp` (Apple-Silicon
   accelerated via Metal) for offline transcription.
2. **Real-time streaming** — pass 30-second rolling chunks directly to the
   Whisper streaming API instead of writing a file.
3. **Speaker diarisation** — use pyannote or a CoreML TDNN model to label
   "who said what".
4. **LLM summary** — POST transcript to any OpenAI-compatible endpoint with
   a user-supplied API key and a meeting-summary prompt.
