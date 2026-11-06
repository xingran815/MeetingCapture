# M3 — Compressed audio, retention, speakers, known bugs

**Goal:** small audio files with no transcription loss, automatic clean-up, and a transcript showing who said what and when.

## Audio pipeline
```text
record 2-track WAV chunks → transcribe + diarize from WAV → encode M4A → verify M4A → delete WAV
```
- Transcribe from WAV, because that guarantees no quality loss. M4A at 64 kbps was about 11× smaller with 98.9% vs 100% word match in the spike.
- **Two tracks:** channel 1 is the mic (`You`), channel 2 is system audio. Replaces today's mono mix; needed for reliable speaker labels. AEC stays on the mic path.
- **M4A:** AAC via `AVAudioFile`/`afconvert`, 64 kbps per channel, one file per chunk. Delete a WAV only after its M4A exists, is non-empty and has a matching duration within 0.5 s, because a failed conversion must not lose the recording. If conversion fails, keep the WAV and say so.
- A crash mid-recording leaves WAV chunks; the next launch offers to process them.
- Existing tools must accept both `.wav` and `.m4a`.

## Retention
- `audioRetentionDays`, default 30, user-changeable (1–3650, or `0` for keep forever) in terminal and desktop.
- Only audio with a sidecar `<base>.mcmeta.json` is managed, and the new version writes that sidecar. **Old recordings are never auto-deleted** (D-10).
- Transcripts, summaries and HTML are kept; retention covers audio only.
- Clean-up runs at launch and after each recording, on the configured output folder; it prints what it deleted. It deletes only the files a sidecar lists, once that recording has a transcript with words in it (D-44, D-45).
- Separate command `--audio-cleanup` lists old unmanaged WAVs, then converts or deletes only after confirmation.

## Speakers
- Mic segments are `You`. Run SpeakerKit on the system track only; its segments become `Speaker 1`, `Speaker 2`, and so on.
- Assign each Whisper segment to the speaker with the most overlap; split at word timestamps where a segment spans two speakers.
- Merge diarization segments under 1 second into a neighbour, because the spike showed a stray 0.6 s speaker.
- The spike also merged a third similar voice into another, so the UI must offer **rename** and **merge speakers**, stored in the sidecar.
- SpeakerKit models download on first use, like Whisper. If diarization fails, keep the transcript with `You` / `Others`.
- With mic off or `--no-mic`: no `You` label.
- The LLM may suggest a real name per speaker, marked unsure, in the report. Never apply it silently.

Terminal format: `[00:01:12] Speaker 1: text`. Same for `.txt`. Show it as the transcript is produced where possible, or at the end.

## Default Whisper model
Switch to `openai_whisper-small` (multilingual), per D-11. Downloaded on first use. Add a `--zh-script simplified|traditional|as-is` post-step or prompt, because both small and medium gave Traditional characters. Default: as-is until tested on real speech.

## Bugs from the code review, each with a test
| Bug | Where | Test |
|---|---|---|
| Chunk offset uses the last segment's end, so trailing silence shifts later timestamps | `Transcribe.swift:164` | Two short chunks with silence at the end of the first |
| Shell transcribe ignores `_partN` files | `Shell.swift:178` | Picks up all parts |
| Speex sample rate left at 8 kHz | `EchoCanceller.swift:67` | Set it to 48 kHz; assert via the ctl getter; listen once |
| Enter doesn't stop a flag-mode recording, despite `--help` | `main.swift` | Share the stop handler with the shell, or correct the text; test on a TTY by hand |
| Duration timer not cancelled; double stop can resume twice | `AudioCapture.swift:209` | Stop twice, then fire the timer: one result, no second "Done" |
| Chrome or Safari can capture silently when the call is elsewhere | `AudioCapture.swift:79` | Print a clear warning naming the target; offer all-audio |
| Progress and "Captured" count paused time | `AudioCapture.swift:348` | Pause in a short test; the count excludes it |
| Start-up box says stereo f32; "Ctrl+C to stop" in shell mode | `AudioCapture.swift:188,207` | Text matches the real format and key |

## Done when
- [ ] From a 2-voice fixture: M4A exists, WAV is gone, the file is at least 8× smaller, and the transcript shows `You` and `Speaker 1` at the right times.
- [ ] A simulated M4A failure keeps the WAV.
- [ ] With an injected clock: managed audio older than the limit goes, younger stays, and old unmanaged WAVs stay.
- [ ] All the bugs above have passing tests, or a noted manual check.
- [ ] One real short call recorded by the user sounds right and labels correctly. **👤 User check.**
- [ ] Verifier passes; `deep-reviewer` and `/security-review` run in parallel, with findings fixed in this PR.
