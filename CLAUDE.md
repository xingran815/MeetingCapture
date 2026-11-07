# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

> **Refactor in progress.** The block at the end of this file and `docs/specs/` win over anything below that disagrees. Sections below describe v0.6 and are rewritten in milestone 6.

**MeetingCapture** — a macOS meeting helper with a terminal UI and, from milestone 5, a desktop app (this replaces the earlier "no GUI" decision). It records a meeting, transcribes it locally with Whisper, and summarizes it with an LLM. Full pipeline is local-first: audio capture and transcription never leave the machine; only transcript text is sent to the chosen LLM.

Current state (v0.6): capture + transcribe + summarize all work. Echo is removed after the call, from the raw mic (M3.2). Indefinite-length recordings with 30-min chunking for fault tolerance. Interactive menu shell is the primary UX; flag-based invocation still works and is the scripting escape hatch.

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
LLMProvider.swift    catalog of LLM provider presets (qianfan/openai/ollama/anthropic/custom) · ReasoningStyle (per-provider reasoning wire format) + host-aware reasoningStyle(baseURL:providerID:) · ReasoningEffort (unified off/low/medium/high depth) · LLMAPIStyle (openAIChat vs anthropicMessages wire protocol) · LLMProfile (one saved, switchable LLM configuration; reasoningEffort + reasoningStyleOverride, with legacy-key migration)
Config.swift         persisted settings (JSON) · llmProfiles tree + active-profile helpers · path/api-key helpers · legacy-path + legacy-schema migration
AudioCapture.swift   SCShareableContent → SCContentFilter → SCStream; owns the WAV writer indirectly
MicCapture.swift     AVAudioEngine input tap · format conversion to 48 kHz mono
EchoRemover.swift    after-the-call echo removal: lag and clock drift → sliding least squares → residual suppressor · EchoEvidence, the delay-and-level check on each mic line
MicStartGate.swift   holds the mic until system audio starts
TrackWriter.swift    two tracks (ch1 mic, ch2 system), writes int16 WAV; 30-min chunk rotation; pause/resume
CMSampleBuffer+PCM.swift  CMSampleBuffer → AVAudioPCMBuffer (handles non-interleaved ABL)
Transcribe.swift     WhisperKit wrapper · language from the loudest 30 s · timestamped segments
RecordingPipeline.swift  recorded files → labelled transcript → M4A, verified → WAV deleted
AudioRetention.swift `<base>.mcmeta.json` sidecar · retention · unfinished recordings
Summarize.swift      POST to the provider's endpoint (OpenAI-compatible /chat/completions OR Anthropic /messages, branched on LLMAPIStyle) · per-provider reasoning serialization (Kimi thinking / OpenAI reasoning_effort / Anthropic adaptive thinking + output_config.effort, from ReasoningStyle + ReasoningEffort) · SummaryStyle (meeting vs therapy) + per-style system prompts (meetingPrompt/therapyPrompt, selected by systemPrompt(for:)) · detectStyle() one-word classifier that auto-routes each transcript · ping() connectivity check
APIKeyStore.swift    file-based LLM API keys, one per profile (~/.config/MeetingCapture/llm_api_keys.json, mode 0600)
Keychain.swift       LEGACY API-key read/delete only — new keys go to APIKeyStore; kept for migration
Sources/Speexdsp/    Not built. Kept only so the echo lab's Speex baseline can be rerun; M6 may delete it
scripts/echo-lab/    M3.2's measuring tools: metrics, every candidate method, word scoring. Real calls only through real_counts.py, which prints counts
install.sh           build (release) → install to ~/.local/bin → trigger TCC prompts
```

Defaults (all overridable via Settings menu or flags):
- Whisper: `openai_whisper-small`, VAD chunking off (D-39)
- LLM: a **tree of named configurations** (`config.llmProfiles: [LLMProfile]`, one of them active via `config.selectedLLMProfileID`; `config.activeLLMProfile` resolves it, falling back to `.first` then a synthesized default). Each `LLMProfile` is self-contained — `name`, `providerID`, `model`, `baseURL`, `reasoningEffort`/`reasoningStyleOverride` — and has its own API key (see APIKeyStore below). The seeded default profile is `qianfan` (`kimi-k2.5` at `https://qianfan.baidubce.com/v2/coding`, Baidu Qianfan coding plan) and stays the default — adding presets doesn't change it. Other presets: `openai`, `ollama`, `anthropic`, `custom` — see `LLMProvider.catalog`. **`anthropic` is the one preset that does NOT speak OpenAI's `/chat/completions`** — it carries `apiStyle: .anthropicMessages` and `Summarizer` branches to Anthropic's native Messages API (`POST {base}/messages`, `x-api-key` + `anthropic-version` headers, required `max_tokens`, top-level `system`, no `temperature`, `content[].text` response). Default model `claude-sonnet-4-6` at `https://api.anthropic.com/v1`. Each profile's `apiStyle` is host-aware (`LLMProvider.apiStyle(baseURL:providerID:)`): an `api.anthropic.com` base URL resolves to the Messages protocol even on a `custom` profile or a `--llm-base-url` override. Settings → LLM configurations lists all profiles (Enter on one makes it active instantly — `n`/`e`/`d` rows add/edit/delete); picking a preset prefills `baseURL`/`model` (still editable); `custom` lets you type your own. You can add any number of custom profiles. Settings → (per profile) Test connection runs a one-token ping (`Summarizer.ping`, `/chat/completions` or `/messages` per protocol).
- Summary style: **auto-detected per transcript, not a setting.** `Summarizer.detectStyle(transcript:)` runs a cheap one-word classifier (sends the first ~6 k chars, asks for `therapy`/`meeting`) just before summarizing; the result picks `meetingPrompt` (the generic Summary/Key points/Decisions/Action items/Open questions recap) vs `therapyPrompt` (a warm, client-facing two-part "Practice Notes": *Part 1 — what happened*, *Part 2 — the therapeutic work* with a homework checklist). A classifier failure is swallowed → falls back to `.meeting`. No config/menu toggle (the user chose pure auto-detect). Flag-mode escape hatch only: `--summary-style meeting|therapy` (and `--therapy` alias) forces a style and skips detection. The classifier reuses the active profile's provider/model/wire-protocol, so it works on both OpenAI-chat and Anthropic-messages endpoints.
- Reasoning mode: **multi-provider, off per profile.** One unified depth knob — `LLMProfile.reasoningEffort: ReasoningEffort` (`off`/`low`/`medium`/`high`) — that each provider maps to its own wire shape (`ReasoningStyle`): Kimi `thinking: {type:"enabled", budget_tokens:N}` (8k/16k/32k), OpenAI `reasoning_effort`, Anthropic `thinking:{type:"adaptive"}` + `output_config.effort`; `Summarizer` serializes per style. The format is resolved **detect + override**, mirroring `apiStyle`: `LLMProvider.reasoningStyle(baseURL:providerID:)` auto-detects by host (anthropic/qianfan·baidubce/openai), and `LLMProfile.reasoningStyleOverride` (set via Settings → Edit → "Reasoning format") forces a format on an unrecognized custom endpoint. `LLMProfile.effectiveReasoningStyle` = override ?? detect; `supportsReasoning` = effectiveReasoningStyle ≠ `.none`. Reasoning still requires a reasoning-capable model for that provider (e.g. an OpenAI o-series/gpt-5, not `gpt-4o-mini`); a model that rejects the param surfaces the provider's error. Ollama defaults to `.none` (use the override for local reasoning models). The editor offers a `5) Reasoning effort` picker + an `f) Reasoning format` override.
- Output dir: `~/Documents/MeetingCapture`
- Duration: 480 min (8h safety cap; Enter to stop, Space+Enter to pause/resume; recordings chunked every 30 min)
- WAV while recording: interleaved two-track int16 @ 48 kHz (~11 MB/min), then M4A once proven good
- Audio source: meeting-app auto-detect on (all 5 apps enabled). Settings → Audio source has an explicit "All system audio" toggle (`config.captureAllAudio`) that bypasses auto-detection; equivalent to the `--all-audio` flag.

API key resolution is **per profile** (first hit wins): `--llm-api-key` flag → `LLM_API_KEY` env → `QIANFAN_API_KEY` env (legacy; both env vars are global, not per-profile — an escape hatch, not the normal path) → that profile's entry in the `APIKeyStore` JSON map (`~/.config/MeetingCapture/llm_api_keys.json`, mode 0600, keyed by `LLMProfile.id`). `Config.resolveApiKey(profileID:flag:)` / `Config.apiKeySource(profileID:)` take the profile id explicitly — callers always resolve against `config.activeLLMProfile.id` (shell) or the `--llm-profile`-selected profile (flag mode). The key file is set/cleared from Settings → LLM configurations → Edit → API key; it is kept OUT of `config.json` so the JSON stays safe to share. Note: a plaintext 0600 file is the user's explicit choice over the Keychain.

A pre-multi-profile config (flat `llmProviderID`/`llmModel`/`llmBaseURL`/... keys, no `llmProfiles`) is migrated on first load into a single `LLMProfile` with the fixed id `Config.migratedLegacyProfileID` ("migrated-legacy") so its one legacy key (old `~/.config/MeetingCapture/llm_api_key` file, then legacy Keychain) can be migrated into the new keystore under a predictable id; `Config.load()` then rewrites `config.json` to the new schema even if the user changes nothing that run.

Settings JSON: `~/.config/MeetingCapture/config.json` (moved from `~/Library/Application Support/MeetingCapture/`; the old path is read once and migrated forward on first load, non-destructively). Corrupt file → defaults + warning + a `config.json.corrupt` copy beside it, because the next Settings change saves over the original (D-54). Retention is then keep-forever (D-52).

## Architecture gotchas

These are load-bearing and not obvious from reading a single file:

- **SCStream always needs video.** Audio-only isn't a thing in ScreenCaptureKit. `AudioCapture` sets a 2×2 / 1 fps dummy video stream so the video path costs nothing.
- **WAV can't store non-interleaved PCM**, and AVAudioFile silently rewrites the file header to interleaved — which then mismatches a non-interleaved write buffer and crashes. `CMSampleBuffer+PCM.swift` interleaves on the fly; `TrackWriter` opens AVAudioFile as interleaved mono int16. Do not try to "simplify" back to non-interleaved. Internal mixing is float32; the float→int16 clamp + scale happens at the write boundary in `pushSystem()`.
- **Pause drops frames; it does not splice silence.** `TrackWriter.togglePause()` early-returns from `pushSystem`/`pushMic` while paused, and clears the mic FIFO on pause-entry to avoid a splice on resume. Audio time stays contiguous in the WAV — wall-clock pause gap simply doesn't exist in the file. Transcript timestamps reflect audio time.
- **System audio drives the mix clock.** `TrackWriter.pushSystem()` consumes a matching number of mic frames from a FIFO per call. Mic FIFO is capped at 1 s to prevent unbounded growth if the mic is disconnected mid-recording.
- **Long recordings are chunked.** `TrackWriter` rotates to a new WAV file every 30 minutes (`meeting.wav`, `meeting_part2.wav`, ...). This provides fault tolerance — if a crash occurs at minute 45, the first chunk is preserved. `Transcribe.transcribe(wavPaths:)` concatenates chunks with adjusted timestamps.
- **VAD chunking is off for every model (D-39).** On `.en` it lost speech after silence, and a separated track is mostly silence. An earlier 22 s dropout at a 30 s window boundary was why it was on; that isn't proven gone, so watch for it. `scripts/e2e.sh` proves speech after silence survives.
- **Only a recording's own listed files may be deleted (D-44).** Retention goes by the sidecar's `audioFiles`, never by name matching, and only after `transcribedAt` is set, which a kept WAV or a track that sounds like only noise prevents (D-52, D-54, D-56). It covers the configured output folder only (D-45). Anything that deletes audio needs a test where a similarly named file survives.
- **Keys work before capture is live, so stops are held until `RecordingStopper.arm()`.** Without that, an early Enter hung the recording forever.
- **`--two-track-*` and `--finish-recording` need `MEETINGCAPTURE_E2E=1`,** because they overwrite and delete by path. Without it they stop with an error, rather than falling through to a real capture.
- **Mid-recording stop/pause uses stdin readability, not readLine.** `Shell.recordFlow()` installs `FileHandle.standardInput.readabilityHandler` before awaiting `capture.run()`, and removes it after. The handler dispatches on input: bare `" "` (after stripping CR/LF) → `pauseToggle()`, anything else → `manualStop()`. A blocking `readLine()` in a detached Task would leak the thread because Swift can't cancel blocking syscalls. Handler approach is clean. **Caveat:** the handler only fires on a real TTY — when stdin is piped (testing), libc fully buffers stdin and the FileHandle dispatch source never sees subsequent bytes. Pause/stop are not reachable from piped tests; verify via interactive tty.
- **`setbuf(stdout, nil)`** at the top of `main.swift` makes prompts and progress flush correctly and kept an early crash visible. Do not remove.
- **Sendable warnings exist** on `AudioCapture`'s Task/DispatchQueue captures. They're left as warnings deliberately; making the class an actor is a bigger refactor than we've invested in.
- **The mic is recorded raw, and the raw audio is the permanent record (D-65).** Echo comes off after the call in `EchoRemover`. `<base>.m4a` is always the raw recording; `<base>_clean.m4a` is an extra, listed in the sidecar so retention removes both. A failed clean falls back to raw and loses nothing. Never prove or archive audio from the cleaned file alone.
- **The two clocks differ by about 8 ppm, so the lag moves during a call (D-66).** On `main-3` it climbs from 144 to 148 ms. A fixed or slowly adapting filter can't follow that: batch least squares got 8.7 dB without correcting the drift, 18.6 dB with it. `EchoRemover` measures the lag across the file, warps the reference, and fits again every 2 s.
- **A fit needs far more reference than taps.** Under 2 s of far side in the window, it reproduces the user's voice and subtracts it, so that window reuses the last good filter. The shift has to be the lag at the warp's pivot, not the median, or a fast mic clock puts the echo out of reach. One shift can't follow a lag step mid-part: that's only noted.
- **Echo maths needs doubles.** Float32 in the Toeplitz solve loses about 10 dB. The lag search also has a false peak at exactly 0 in some windows, so it ignores under 2 ms and takes a median.
- **No echo peak means leave the mic alone.** With headphones `clean` returns nil, and the raw mic is transcribed. An echo that leads the reference is left alone too.
- **A repeat isn't an echo, so labels go by delay and level, never by text (D-67).** A mic line is left out only if cleaning took at least 10 dB off the mic's loudest fifth and the cleaned loudest fifth is under a ceiling: 15 dB above the room, or 10 dB under this recording's own voice if that's lower. Talk-over also shows a big drop, so only level protects a soft speaker. The note and the sidecar give the times of left-out lines, never their words. Level is a mean of power, so one real word in a long line counts.
- **A broadband echo figure can flatter (D-68).** Room noise is mostly low, so the broadband ceiling on `main-3` is 28 dB, but in the speech band it's 38 dB and the result is 29 dB. Output also falls below the room on some frames, so part of a figure can be room noise removed. Read `part1_speech_band` and the voice figures with any reduction figure. DTLN's 42 dB came with 10 dB off a voice.
- **`words.py`'s repeat score can't see a lost repeat.** With no user voice at all it still scores over 95%, because an echo has the same words as its repeat. `masked_repeats.py` is the real test.
- **Do not enable Apple's Voice-Processing I/O on the mic input.** `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` was tried (commit `a30025f`) to cancel the speaker→mic echo. It works as an AEC, but the API also switches the system audio HAL into "voice chat" mode — that ducks output (overriding user volume) and puts the mic into an exclusive voice-processing path. Any concurrent VoIP app (Zoom, Meet, Teams) that's also using VPIO is then unable to capture the mic, and its playback gets duck-attenuated. Recording becomes unusable in real meetings. **The fix is implemented:** `EchoRemover` works after the call on our own files, so it never claims the HAL session. Disable with `--no-aec` or Settings → Echo removal.

## Extending the tool

Likely next rounds: speaker diarization, custom prompt templates, chunked/streaming summarization (not needed for current transcript sizes — Kimi has 256 k context), a brittle-stdin fix via termios, Chinese-meeting polish (switch default to multilingual `small` and tune the prompt).

When working on the LLM side, follow `docs/specs/02-llm-providers.md`: Qianfan and Kimi are being removed, and the subscription CLIs become the default.

When working on the shell, keep the "one keystroke to record" UX principle. If a feature needs a multi-prompt wizard, put it in the Settings menu.

Settings and the audio-source picker use `Menu.run`, not `Menu.pick`: it stays open and redraws the menu **in place** (clears its block, runs the per-selection handler, re-renders) so changing a setting never prints a fresh stacked copy. Consequence: pure toggles must NOT print confirmations (the `[bracketed]` value already updates on redraw); rely on the menu's own redraw for feedback. In-place redraw only happens on a real TTY — piped stdin falls back to a reprinted numbered list.

The Settings menu is grouped with dimmed `MenuItem.separator(...)` header rows (Capture & transcription / LLM / Audio). Because separators shift row indices, the `Menu.run` handler dispatches on `buildItems()[i].key` (the item's shortcut char), **not** the positional index — so you can reorder rows or add/remove separators without renumbering the `switch`. `Menu.run` only ever calls the handler with the index of an *enabled* row, so separators are never dispatched. Shortcut keys must avoid `j`/`k`/`q`/`b` (reserved by the picker for navigation/back/quit).

<!-- devkit:start -->
## Dev system (devkit) — read this first in every new session

- **Plan:** dev/PLAN.md · **Now:** dev/NOW.md · **Decisions:** dev/DECISIONS.md · **Specs:** docs/specs/ · **Evidence:** dev/evidence/
- **Mode:** 🏢 light production: quick and efficient, with real gates only where listed here. Start with `/next` or "continue"; end with `/next save`.
- **Check command:** `scripts/check.sh` (`--unit`, `--production` by default, `--full`, `--live`); CI runs `scripts/ci.sh <job>`. Done means `--full` passed on the last code change and each Done-when check was seen working.
- **Talk:** short chunks, key point in bold, tables over paragraphs, one-line status updates, at most 4 numbered questions with a recommended answer, reply in the language the user wrote in.

### Rules, because a new session will pick this up cold

| Rule | Because |
|---|---|
| **Build in the main session.** No builder subagents, no worktrees. M3.2 alone uses researcher, developer and reviewer subagents (D-59). | User's rule; keeps the context and the diff in one place. |
| **A fresh Sonnet subagent writes all tests, every time.** The one exception to building in the main session. It reports product bugs and doesn't fix them. | User's rule, D-49. |
| **All E2E tests run locally; CI runs only the short one.** | User's rule, D-49; keeps CI quick. |
| **One branch and one PR per milestone** (`m<n>-<slug>`), closing that milestone's issues. | One PR per milestone is easy to follow. |
| **Hooks gate every commit and push.** Pre-commit: format, lint and secret sweep of the staged text. It doesn't build, so a commit may not compile. Pre-push: identity and leak sweeps of outgoing commits, then `check.sh --unit`, which tests the working copy. It takes about 7 minutes, so push with `GIT_SSH_COMMAND="ssh -o ServerAliveInterval=30"` (D-75). Never use `--no-verify`. | A failed sweep means a leak was about to happen. |
| **Pick the test level by risk.** `check.sh --production` when capture, the pipeline or file deletion changes; `--full` before a milestone's final push. `--full` saves its commit and result in `dev/tmp/check-full.txt`. | Routine checks take seconds, and the slow ones still run where they count. |
| **Sonnet verifier (`verifier` agent) after every milestone**, before merge. It reads the `--full` record instead of rerunning it, checks the commit matches the last code change with a clean tree, and checks each Done-when. | Independent proof that Done-when checks are true. |
| **Deep review (`deep-reviewer`, Opus) at M3, M4 and M6 at minimum,** and at any milestone with code that can lose recordings, delete files, or has tricky concurrency. A **normal reviewer** (`reviewer`) at any milestone end without one. | Deep review is expensive, so it goes by risk. |
| **Security review (`/security-review`) for changes to credentials, data leaving the machine, subprocesses, workflows or dependencies.** | These are where a mistake leaks or runs something. |
| **Review agents run after CI,** unless a spec says otherwise. The M3 and M6 specs run the security and deep reviews in parallel with each other. | Agents then look at code that already builds. |
| **Fix findings in the same PR. Never open a new PR for them.** Lows don't block. After a fix, re-check only the changed lines. There are two rounds to fix; if the same function fails twice, stop and ask. | Keeps one PR per milestone and stops review loops. |
| **Turn each finding into a test where possible**, and name the finding in the test. | The same bug can't come back. |
| **To merge:** `gh pr checks` is green on the exact commit being merged, and required agents cover all code changes. `main` requires CI, for the admin too, and accepts the PR's 7 results on that same commit. The push to `main` then runs its own clean build, unit tests, and leak and identity checks, and saves the build as the cache. | A clean machine proves what hooks on this Mac can't. |
| **Merge locally:** `git switch main && git merge --ff-only <branch> && git push origin main`. Never use GitHub's merge button or `gh pr merge`. | GitHub can stamp the account email on server-made commits. The push closes the PR as merged. |
| **After a merge, comment on each issue** (what landed, evidence, PR link), close it, update dev/NOW.md. | State lives in files and issues. |
| **Merging and pushing task branches and `main` is pre-approved** after the checks pass. | User: "feel free to commit and merge". |
| **Force-push approval is used up.** The one approved rewrite ran on 2026-11-06; never force-push again without a new yes. Ruleset `protect-main` also blocks it, so an approved force-push needs the ruleset changed first. | User's explicit decision, D-05, D-33. |
| **Never push or merge `feature/coding-interview`.** Push only named refs, never `--all` or `--mirror`. | User's rule; the pre-push hook also blocks it, including a renamed copy (D-62). |
| **Commits use the repo-local noreply author.** No `Co-Authored-By` lines for Claude or any AI. | Email must not leak; user's rule. |
| **Never put email, keys, tokens or real transcripts in code, fixtures, issues, PRs, logs or prompts.** Fixtures are invented; read secrets from the environment and mask output. | Public repo, sensitive sessions. |
| **Tests never use a real model, network or 30-minute audio by default.** Fake CLIs on `PATH`, injected clocks and chunk lengths, and 5–30 second `say` fixtures. `--live` is opt-in. | Fast tests that don't spend subscription usage. |
| **In scripts, capture output before matching it.** `cmd \| grep -q x` under `pipefail` can read a match as no match: `grep` exits at the first hit and `cmd` gets SIGPIPE. | It made a self-test fail, and another flaky without showing (M3.1). |
| **Say when unsure,** in code comments, reports and LLM prompts alike. | User's rule for the product and for us. |
| **After each compaction, re-read the files before anything else:** this file, `dev/NOW.md`, `dev/PLAN.md`, the end of `dev/DECISIONS.md`, the current spec and latest report, `git status` and `git log`. Where a summary disagrees, the files and git win. | User's rule; a summary is a recollection, the files are the facts. |
| **Close every milestone with a report and rules on disk, then start the next one without waiting.** Steps below. | User's rule; only what's in files survives a session. |

### Closing a milestone, then starting the next
Order: M1 → M2 → M2.1 → M3 → M3.1 → M3.2 → M4 → M5 → M6.

1. **Save, on the milestone branch, once the verifier (and deep review, where required) has passed:**
   - `dev/evidence/<date>-m<n>-report.md`: what landed, each Done-when with its evidence, every verifier and review finding with the test it became, surprises, what's still unsure, and what the next milestone needs to know.
   - New rules go in this file, decisions in `dev/DECISIONS.md`, status in `dev/PLAN.md`, and the next milestone's exact first step in `dev/NOW.md`. Use the `lesson` skill where something hurt.
   - Reports are public: invented data only, and the sweeps apply.
2. **Commit, merge and close the issues,** using the rules above.
3. **Check nothing lives only in the conversation:** `git status` is clean, `main` matches `origin/main`, and `dev/NOW.md` names the next step.
4. **Start the next milestone in this same session.** Don't start a new session or clear this one. Don't try to compact on purpose either; the app may still compact on its own when context runs long, which is why step 1 comes first.

**Starting automatically never skips a gate.** Stop and ask at a 👤 check, a decision only the user can make, or a failure you can't fix. A milestone with an open 👤 check isn't closed, and the next one doesn't start. Only one session builds at a time.

Long commands run in the background with a time limit and a log in `dev/tmp/`; macOS has no `timeout`, so use the Bash tool's timeout or `perl -e 'alarm shift; exec @ARGV'`.
<!-- devkit:end -->
