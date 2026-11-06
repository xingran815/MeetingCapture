# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

> **Refactor in progress.** The block at the end of this file and `docs/specs/` win over anything below that disagrees. Sections below describe v0.6 and are rewritten in milestone 6.

**MeetingCapture** — a macOS meeting helper with a terminal UI and, from milestone 5, a desktop app (this replaces the earlier "no GUI" decision). It records a meeting, transcribes it locally with Whisper, and summarizes it with an LLM. Full pipeline is local-first: audio capture and transcription never leave the machine; only transcript text is sent to the chosen LLM.

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
LLMProvider.swift    catalog of LLM provider presets (qianfan/openai/ollama/anthropic/custom) · ReasoningStyle (per-provider reasoning wire format) + host-aware reasoningStyle(baseURL:providerID:) · ReasoningEffort (unified off/low/medium/high depth) · LLMAPIStyle (openAIChat vs anthropicMessages wire protocol) · LLMProfile (one saved, switchable LLM configuration; reasoningEffort + reasoningStyleOverride, with legacy-key migration)
Config.swift         persisted settings (JSON) · llmProfiles tree + active-profile helpers · path/api-key helpers · legacy-path + legacy-schema migration
AudioCapture.swift   SCShareableContent → SCContentFilter → SCStream; owns the WAV writer indirectly
MicCapture.swift     AVAudioEngine input tap · format conversion to 48 kHz mono
EchoCanceller.swift  Speex-based acoustic echo cancellation (software AEC)
MixingWriter.swift   sums mic + system, downmixes to mono, writes int16 WAV; 30-min chunk rotation; pause/resume
CMSampleBuffer+PCM.swift  CMSampleBuffer → AVAudioPCMBuffer (handles non-interleaved ABL)
Transcribe.swift     WhisperKit wrapper · VAD chunking · timestamped .txt
Summarize.swift      POST to the provider's endpoint (OpenAI-compatible /chat/completions OR Anthropic /messages, branched on LLMAPIStyle) · per-provider reasoning serialization (Kimi thinking / OpenAI reasoning_effort / Anthropic adaptive thinking + output_config.effort, from ReasoningStyle + ReasoningEffort) · SummaryStyle (meeting vs therapy) + per-style system prompts (meetingPrompt/therapyPrompt, selected by systemPrompt(for:)) · detectStyle() one-word classifier that auto-routes each transcript · ping() connectivity check
APIKeyStore.swift    file-based LLM API keys, one per profile (~/.config/MeetingCapture/llm_api_keys.json, mode 0600)
Keychain.swift       LEGACY API-key read/delete only — new keys go to APIKeyStore; kept for migration
Sources/Speexdsp/    Vendored xiph/speexdsp (BSD-3) — MDF echo canceller + preprocessor
install.sh           build (release) → install to ~/.local/bin → trigger TCC prompts
```

Defaults (all overridable via Settings menu or flags):
- Whisper: `openai_whisper-small.en`, VAD chunking on
- LLM: a **tree of named configurations** (`config.llmProfiles: [LLMProfile]`, one of them active via `config.selectedLLMProfileID`; `config.activeLLMProfile` resolves it, falling back to `.first` then a synthesized default). Each `LLMProfile` is self-contained — `name`, `providerID`, `model`, `baseURL`, `reasoningEffort`/`reasoningStyleOverride` — and has its own API key (see APIKeyStore below). The seeded default profile is `qianfan` (`kimi-k2.5` at `https://qianfan.baidubce.com/v2/coding`, Baidu Qianfan coding plan) and stays the default — adding presets doesn't change it. Other presets: `openai`, `ollama`, `anthropic`, `custom` — see `LLMProvider.catalog`. **`anthropic` is the one preset that does NOT speak OpenAI's `/chat/completions`** — it carries `apiStyle: .anthropicMessages` and `Summarizer` branches to Anthropic's native Messages API (`POST {base}/messages`, `x-api-key` + `anthropic-version` headers, required `max_tokens`, top-level `system`, no `temperature`, `content[].text` response). Default model `claude-sonnet-4-6` at `https://api.anthropic.com/v1`. Each profile's `apiStyle` is host-aware (`LLMProvider.apiStyle(baseURL:providerID:)`): an `api.anthropic.com` base URL resolves to the Messages protocol even on a `custom` profile or a `--llm-base-url` override. Settings → LLM configurations lists all profiles (Enter on one makes it active instantly — `n`/`e`/`d` rows add/edit/delete); picking a preset prefills `baseURL`/`model` (still editable); `custom` lets you type your own. You can add any number of custom profiles. Settings → (per profile) Test connection runs a one-token ping (`Summarizer.ping`, `/chat/completions` or `/messages` per protocol).
- Summary style: **auto-detected per transcript, not a setting.** `Summarizer.detectStyle(transcript:)` runs a cheap one-word classifier (sends the first ~6 k chars, asks for `therapy`/`meeting`) just before summarizing; the result picks `meetingPrompt` (the generic Summary/Key points/Decisions/Action items/Open questions recap) vs `therapyPrompt` (a warm, client-facing two-part "Practice Notes": *Part 1 — what happened*, *Part 2 — the therapeutic work* with a homework checklist). A classifier failure is swallowed → falls back to `.meeting`. No config/menu toggle (the user chose pure auto-detect). Flag-mode escape hatch only: `--summary-style meeting|therapy` (and `--therapy` alias) forces a style and skips detection. The classifier reuses the active profile's provider/model/wire-protocol, so it works on both OpenAI-chat and Anthropic-messages endpoints.
- Reasoning mode: **multi-provider, off per profile.** One unified depth knob — `LLMProfile.reasoningEffort: ReasoningEffort` (`off`/`low`/`medium`/`high`) — that each provider maps to its own wire shape (`ReasoningStyle`): Kimi `thinking: {type:"enabled", budget_tokens:N}` (8k/16k/32k), OpenAI `reasoning_effort`, Anthropic `thinking:{type:"adaptive"}` + `output_config.effort`; `Summarizer` serializes per style. The format is resolved **detect + override**, mirroring `apiStyle`: `LLMProvider.reasoningStyle(baseURL:providerID:)` auto-detects by host (anthropic/qianfan·baidubce/openai), and `LLMProfile.reasoningStyleOverride` (set via Settings → Edit → "Reasoning format") forces a format on an unrecognized custom endpoint. `LLMProfile.effectiveReasoningStyle` = override ?? detect; `supportsReasoning` = effectiveReasoningStyle ≠ `.none`. Reasoning still requires a reasoning-capable model for that provider (e.g. an OpenAI o-series/gpt-5, not `gpt-4o-mini`); a model that rejects the param surfaces the provider's error. Ollama defaults to `.none` (use the override for local reasoning models). The editor offers a `5) Reasoning effort` picker + an `f) Reasoning format` override.
- Output dir: `~/Documents/MeetingCapture`
- Duration: 480 min (8h safety cap; Enter to stop, Space+Enter to pause/resume; recordings chunked every 30 min)
- WAV output: interleaved mono int16 @ 48 kHz (~5.6 MB/min)
- Audio source: meeting-app auto-detect on (all 5 apps enabled). Settings → Audio source has an explicit "All system audio" toggle (`config.captureAllAudio`) that bypasses auto-detection; equivalent to the `--all-audio` flag.

API key resolution is **per profile** (first hit wins): `--llm-api-key` flag → `LLM_API_KEY` env → `QIANFAN_API_KEY` env (legacy; both env vars are global, not per-profile — an escape hatch, not the normal path) → that profile's entry in the `APIKeyStore` JSON map (`~/.config/MeetingCapture/llm_api_keys.json`, mode 0600, keyed by `LLMProfile.id`). `Config.resolveApiKey(profileID:flag:)` / `Config.apiKeySource(profileID:)` take the profile id explicitly — callers always resolve against `config.activeLLMProfile.id` (shell) or the `--llm-profile`-selected profile (flag mode). The key file is set/cleared from Settings → LLM configurations → Edit → API key; it is kept OUT of `config.json` so the JSON stays safe to share. Note: a plaintext 0600 file is the user's explicit choice over the Keychain.

A pre-multi-profile config (flat `llmProviderID`/`llmModel`/`llmBaseURL`/... keys, no `llmProfiles`) is migrated on first load into a single `LLMProfile` with the fixed id `Config.migratedLegacyProfileID` ("migrated-legacy") so its one legacy key (old `~/.config/MeetingCapture/llm_api_key` file, then legacy Keychain) can be migrated into the new keystore under a predictable id; `Config.load()` then rewrites `config.json` to the new schema even if the user changes nothing that run.

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
- **Do not enable Apple's Voice-Processing I/O on the mic input.** `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` was tried (commit `a30025f`) to cancel the speaker→mic echo. It works as an AEC, but the API also switches the system audio HAL into "voice chat" mode — that ducks output (overriding user volume) and puts the mic into an exclusive voice-processing path. Any concurrent VoIP app (Zoom, Meet, Teams) that's also using VPIO is then unable to capture the mic, and its playback gets duck-attenuated. Recording becomes unusable in real meetings. **The fix is implemented:** software AEC via vendored `speexdsp` running in user-space against our own mic and SCStream buffers — that path doesn't claim the HAL session. Disable with `--no-aec` or Settings → AEC if needed.

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
- **Check command:** `scripts/check.sh`. Done means it passes and each Done-when check was seen working.
- **Talk:** short chunks, key point in bold, tables over paragraphs, one-line status updates, at most 4 numbered questions with a recommended answer, reply in the language the user wrote in.

### Rules, because a new session will pick this up cold

| Rule | Because |
|---|---|
| **Build in the main session.** No builder subagents, no worktrees. | User's rule; keeps the context and the diff in one place. |
| **One branch and one PR per milestone** (`m<n>-<slug>`), closing that milestone's issues. | Six PRs are easy to follow. |
| **Run the tests, then commit.** The git hooks enforce `scripts/check.sh --fast` and the sweeps. Never use `--no-verify`. | A failed sweep means a leak was about to happen. |
| **Sweep before every commit and before every push**: identity, secrets, security. | Repo is public. |
| **Sonnet verifier (`verifier` agent) after every milestone**, before merge. | Independent proof that Done-when checks are true. |
| **Opus deep review (`deep-reviewer` agent) only after M3, M4, M6**, before merge. | Deep review is expensive; these are the risky milestones. |
| **Fix findings in the same PR. Never open a new PR for them.** Lows don't block; re-checks look at changed lines only. | Keeps one PR per milestone and stops review loops. |
| **Turn each finding into a test where possible**, and name the finding in the test. | The same bug can't come back. |
| **Merge locally:** `git switch main && git merge --ff-only <branch> && git push origin main`. Never use GitHub's merge button or `gh pr merge`. | GitHub can stamp the account email on server-made commits. The push closes the PR as merged. |
| **After a merge, comment on each issue** (what landed, evidence, PR link), close it, update dev/NOW.md. | State lives in files and issues. |
| **Merging and pushing task branches and `main` is pre-approved** after the checks pass. | User: "feel free to commit and merge". |
| **Force-push approval is used up.** The one approved rewrite ran on 2026-11-06; never force-push again without a new yes. | User's explicit decision, D-05. |
| **Never push or merge `feature/coding-interview`.** Push only named refs, never `--all` or `--mirror`. | User's rule; the pre-push hook also blocks it. |
| **Commits use the repo-local noreply author.** No `Co-Authored-By` lines for Claude or any AI. | Email must not leak; user's rule. |
| **Never put email, keys, tokens or real transcripts in code, fixtures, issues, PRs, logs or prompts.** Fixtures are invented; read secrets from the environment and mask output. | Public repo, sensitive sessions. |
| **Tests never use a real model, network or 30-minute audio by default.** Fake CLIs on `PATH`, injected clocks and chunk lengths, and 5–30 second `say` fixtures. `--live` is opt-in. | Fast tests that don't spend subscription usage. |
| **Say when unsure,** in code comments, reports and LLM prompts alike. | User's rule for the product and for us. |

Long commands run in the background with a time limit and a log in `dev/tmp/`; macOS has no `timeout`, so use the Bash tool's timeout or `perl -e 'alarm shift; exec @ARGV'`.
<!-- devkit:end -->
