# M3: trial on one real recording, and silence on split tracks

Date: 2026-11-06. The recording and its transcripts stayed on the owner's Mac, in a private temporary copy. Nothing from them is in this repo, and no LLM saw them. Only counts are recorded here.

## The recording
One 30-minute file, mono, made by the earlier build, so it mixes mic and system audio together. It can test speed, timing and speaker detection on real speech. **It can't test `You`,** which needs a two-track recording. It doesn't replace M3's 👤 real call.

## Results
| Setup | Words | Lines | Largest gap | Time |
|---|---|---|---|---|
| Earlier pipeline's transcript, first 30 min | 3,196 | 289 | 21 s | not measured |
| `small.en`, VAD on | 3,179 | 300 | 21 s | not measured |
| `small.en`, VAD off | 3,148 | 242 | 29 s | 84 s to transcribe |
| `small`, VAD off (new default) | 3,131 | 265 | 22 s | 86 s to transcribe, 145 s in all |

Speaker detection found 2 speakers, with 32 speaker changes. Timestamps stay in order through 29:58. **Whether the labels are right hasn't been checked;** that needs someone who knows the call.

## Finding: VAD lost speech after silence
Invented audio: a short sentence placed after silence, on `small.en` and `small`.

| Audio | `small.en`, VAD on | `small.en`, VAD off | `small`, VAD off |
|---|---|---|---|
| 6 s silence, then speech | **lost** | kept | kept |
| 60 s silence, then speech | **lost** | kept | kept |
| Speech, 120 s silence, speech | **second sentence lost** | kept | kept |
| Speech, then 120 s silence | kept | kept | kept |
| 60 s silence only | no invented speech | no invented speech | no invented speech |

A mixed recording rarely has that much silence, but a separated track is mostly silence. So VAD is off for every model (D-39), and `scripts/e2e.sh` keeps this true: its system track opens with 6 s of silence.

## Still unsure
- **About 1% fewer words with VAD off** on `small.en` (31 of 3,179). At the 29 s gap the VAD run has 36 words where this run has one 19-word segment, so some speech may be lost or merged there. Counts can't settle this, and the text wasn't read.
- **Digital silence only.** A real mic track has room noise, which may make Whisper invent words. The 👤 real call is the first test of that.
- **The earlier 22 s dropout** that led to VAD wasn't reproduced here; it's only absent from these runs.
- **`--language` wasn't pinned for the real runs:** `small` detected English by itself.
