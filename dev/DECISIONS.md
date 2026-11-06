# Decisions

One line per decision: `D-NN · date · decision · why · by`.

- D-01 · 2026-11-06 · Light production: quick and efficient, with gates only where listed in CLAUDE.md · a personal professional tool · by user
- D-02 · 2026-11-06 · No LangChain or LangGraph; Swift provider layer around official CLIs · they add no subscription access · by Claude, user informed, spec open to change
- D-03 · 2026-11-06 · Build in the main session; Sonnet verifier each milestone; Opus deep review after M3, M4, M6; fixes stay in the same PR; findings become tests · speed and clear review points · by user
- D-04 · 2026-11-06 · At most 10 issues at the start, one PR per milestone · easy to follow · by user (limit), Claude (PR grouping)
- D-05 · 2026-11-06 · Rewrite all of `main`'s history to a noreply author and force-push once · the GitHub privacy setting doesn't cover local commits · by user
- D-06 · 2026-11-06 · Author: GitHub login with numeric noreply address, repo-local; name in commits and LICENSE is acceptable, the email is not · user said only the email matters · by user
- D-07 · 2026-11-06 · Claude runs all tiers when both CLIs exist; no mixing; Codex only when usage is full; Qianfan and Kimi removed; DeepSeek kept · by user
- D-08 · 2026-11-06 · Regex-only redaction, on by default, hush as reference; spoken names are still sent · lightweight, chosen knowing names aren't caught · by user
- D-09 · 2026-11-06 · Six desktop options vary the app's shape; decide when reviewing · by user
- D-10 · 2026-11-06 · Retention default 30 days, audio only, new recordings only · old files can't be recovered once deleted · by user (old audio), Claude (transcripts kept)
- D-11 · 2026-11-06 · Default Whisper is multilingual `small`, downloaded on first use · by user
- D-12 · 2026-11-06 · Speakers: mic is You, diarization on system audio gives Speaker N, real names only as unsure suggestions · by user
- D-13 · 2026-11-06 · Therapy web search uses concept names only, in a call with no transcript · by user
- D-14 · 2026-11-06 · Six scenarios: meeting, therapy, interview, one-on-one, lecture, general; templates as data · by user
- D-15 · 2026-11-06 · HTML: LLM fills JSON, one template renders it; `<timestamp>_<short-topic>.html` · by user
- D-16 · 2026-11-06 · Merge locally by fast-forward, never on GitHub's servers · server merges can stamp the account email · by Claude
- D-17 · 2026-11-06 · Keep OpenAI API, Anthropic API, Ollama and custom profiles in terminal config · user only asked to remove Qianfan and Kimi · Assumed
