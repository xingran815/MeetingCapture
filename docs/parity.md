# Desktop and terminal parity

Spec 05: the terminal has every desktop feature, plus finer settings. Check this list when either side changes; `ParityTests` checks the terminal side.

| Feature | Desktop | Terminal |
|---|---|---|
| Record | Record button, toolbar, ⌘R | Main menu 1 |
| Pause, resume | Pause button, ⇧⌘P | Space then Enter while recording |
| Stop | Stop button, ⌘. | Enter while recording |
| Audio source: meeting apps or all audio, which apps, mic | Settings › Recording | Settings › s Audio source, m Mic capture |
| Library | Sidebar | Main menu 6 |
| Open a report | Select it in the sidebar | Library › o Open report |
| Transcribe again | Re-run menu, Recording menu | Library › t |
| Write the report again | Re-run menu, Recording menu | Library › w |
| Process an unfinished recording | Process Now | Offered at start |
| Show in Finder | Toolbar | Library › f |
| Rename and merge speakers | Speakers sheet | Main menu 4, Library › s |
| Primary CLI | Settings › Summaries | Settings › c LLM route |
| Usage today | Settings › Summaries | Settings, the two usage lines |
| Connection test | Settings › Summaries › Test | Settings › k Test CLI connection |
| Keep audio for (days) | Settings › General | Settings › d |
| Output folder | Settings › General | Settings › 3 |
| Whisper model | Settings › General | Settings › 1 |
| Redaction on or off | Settings › Summaries | Settings › x |
| Download models with progress, cancel, resume | First-run screen | Downloaded on first transcribe |

Terminal only: per-tier CLI models, reasoning, API profiles, `--scenario`, language pin, echo removal settings, chunk length, daily call cap, safety cap, auto-transcribe and auto-summarize, flags for scripting.
