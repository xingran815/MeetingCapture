# Security

## Reporting a problem

Please don't describe a vulnerability in a public issue. Open an issue titled
**"Security contact"** with no details, and the maintainer will reply with a
private way to send them. Never include real recordings, transcripts or keys;
invented examples are enough. This is a personal project, so a reply can take a
few days.

## What leaves the machine

| Data | Leaves the Mac? | Where to |
|---|---|---|
| Audio (WAV, M4A) | Never | Stays in the output folder |
| Transcription and speaker turns | Never | WhisperKit and SpeakerKit run locally; models are downloaded once from Hugging Face |
| Transcript text | Yes, for a report | The `claude` or `codex` CLI you logged in to (Anthropic or OpenAI), or the endpoint of the API configuration you chose. Formatted values are replaced with tokens first |
| Your notes on a report | Only if you turn that on for that report | Same as the transcript, redacted with it |
| A group's earlier reports | Only for a report in a group | Same; allow-listed fields only (titles, sections, item text, keywords, your edits, and that report's notes when its notes switch is on), never transcripts, quotes or review notes. Redacted with the transcript unless the group's switch is off, in which case this context goes as written |
| Concept names | Yes, for the search step | The CLI's web search, in a call that holds no transcript text. The model is told to keep names generic and renamed speakers' names are filtered, but a name the model writes into a concept (such as "Dana's attachment pattern") can get through |
| API keys | Only to their own endpoint | Kept in `~/.config/MeetingCapture/llm_api_keys.json` (mode 0600), never in `config.json`, never logged |
| CLI login tokens | Never touched | MeetingCapture doesn't read, store or forward them |

**Redaction is regex only.** It catches emails (also spoken), API keys, tokens
in URLs, IBANs, card numbers, phone numbers, US SSNs, and Chinese ID and mobile
numbers. **It does not catch names**, addresses, or anything said without a
fixed format. Assume the model provider sees them.

## How the code limits harm

- CLIs run with `Process` and an argument array, never a shell, in a new empty
  temporary folder, with an allow-listed environment (`HOME`, `PATH`, `USER`,
  `TMPDIR`). A CLI that would bill an API key is refused unless the user opts in.
- Tools are off for every call that contains transcript text.
- Reports are rendered by the app, not the model: all text is escaped, only
  `http` and `https` links are kept, and the page's Content Security Policy
  blocks outside requests. The desktop app's report view loads nothing but the
  page itself and sends links to the browser.
- Deleting is narrow: retention and Move to Trash touch only the files a
  recording's `.mcmeta.json` lists. Delete moves them to the Trash, never
  removes them for good.

## What the repository's sweeps do

| When | Check |
|---|---|
| Every commit (pre-commit, commit-msg) | `swift format`, `shellcheck`, `actionlint`; a secret sweep of the staged text (API keys, tokens, private keys, passwords in URLs, credential logging, shell spawning, invisible characters); personal emails and home-folder paths; AI attribution lines in the message |
| Every push (pre-push) | The same leak sweeps over each outgoing commit, its message and its diff; noreply author and committer; the protected branch and its known commits refused |
| CI | The leak and identity sweeps again on a clean machine; any audio or video file blocked except two invented test clips |

Findings name the rule, file and line, never the matched value.

## What the sweeps don't catch

- **Real content that looks ordinary.** A real name, a real transcript pasted as
  a "fixture", or a description of a real conversation passes every regex.
  Fixtures and reports must use invented data; that is a rule for people, not a
  check.
- Secrets in a format none of the patterns knows.
- A file marked `-diff` or `binary` in `.gitattributes`, which hides its text
  from the diff-based sweeps.
- A rebased or cherry-picked copy of a protected commit, whose id is new.
- Anything pushed with `--no-verify`, until CI runs. Don't use it.

Once something is public it can't be fully recalled, so the sweeps block before
the push rather than report after it.
