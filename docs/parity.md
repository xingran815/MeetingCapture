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
| Rename the title | More › Rename…, Recording menu | Library › r |
| Notes | Notes button (⌥⌘N), edited in place | Library › n opens them in `$EDITOR`, else the default text editor |
| Send notes to the LLM (off by default) | Notes › Use notes when writing the report | Library › l |
| Write the report again, keeping or dropping edits | Asked when the report has edits | Asked when the report has edits |
| Delete a recording, to the Trash | More › Move to Trash…, ⌘⌫ | Library › d |
| Put a report in a group, a new group, or none | More › Group | Library › g |
| Make, rename, delete groups | More › Group › Manage Groups…, Recording menu | Main menu 7 |
| A group's context redaction switch (on by default) | Manage Groups › Redact the context | Main menu 7 › group › x |
| A group's pinned scenario | Manage Groups › Scenario | Main menu 7 › group › c |
| Take a report out of a group | More › Group › No Group | Library › g › x, Main menu 7 › group › m |
| Write a report with the group's context | Re-run › Write the Report Again (automatic in a group) | Library › w (automatic in a group; says which) |
| See groups | Sidebar sections | Main menu 7, Library › g shows the group |
| Primary CLI | Settings › Summaries | Settings › c LLM route |
| Usage today | Settings › Summaries | Settings, the two usage lines |
| Connection test | Settings › Summaries › Test | Settings › p Test CLI connection |
| Keep audio for (days) | Settings › General | Settings › d |
| Output folder | Settings › General | Settings › 3 |
| Whisper model | Settings › General | Settings › 1 |
| Redaction on or off | Settings › Summaries | Settings › x |
| Download models with progress, cancel, resume | First-run screen | Downloaded on first transcribe |

Desktop only: editing the report's text (More › Edit Report…), and keeping or dropping edits that no longer match (D-93). The terminal shows edits and says when some no longer match.

Terminal only: per-tier CLI models, reasoning, API profiles, `--scenario`, language pin, echo removal settings, chunk length, daily call cap, safety cap, auto-transcribe and auto-summarize, flags for scripting.
