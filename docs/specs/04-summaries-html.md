# M4 — Scenario summaries and the HTML report

**Goal:** a report whose sections fit what the meeting actually was, reviewed by a frontier model, honest about doubt, in a fixed HTML framework.

## Pipeline
| Step | Tier | Input | Output |
|---|---|---|---|
| 1. Classify | Cheap | Transcript head and sample | `{scenario, topic, language, confidence}` |
| 2. Sections | Normal | Transcript, scenario template | JSON matching that scenario's schema |
| 3. Concepts (therapy, lecture) | Normal, tools on | **Concept names only** | Explanations with sources |
| 4. Review | Frontier | Transcript, step 2–3 JSON | Corrected JSON, plus a list of what changed and why |
| 5. Render | None | Final JSON | HTML, no model involved |

Transcript corrections from step 4 are proposed per segment and shown as suggestions; the original transcript text is kept. If a step fails: steps 1 and 3 degrade (general template, no sources); a failed step 4 ships step 2 with a banner saying it wasn't reviewed.

Every model-written item may carry `confidence: "unsure"` and a reason; prompts say **"If you aren't sure, say so. If you don't have an answer, say you don't."**

## Scenarios
Templates are data (one JSON file each), so adding a scenario needs no code. Low-confidence classification uses `general` and says so.

| Scenario | Sections |
|---|---|
| `meeting` (company) | Summary · Who said what (bullets by speaker) · Open questions, each with an AI answer or "I don't know" · Actions and to-dos, with owner and due date · AI insights: what you can do |
| `therapy` | Summary · Issues raised by the client · Therapist's suggestions or inspirations per issue · To-dos and actions · SMART goals made with the client's words · Concepts to explore: what the therapist said, what the AI understands, more detailed explanation, sources · AI insights on each issue, marked as AI, not as clinical advice |
| `interview` | Summary · Questions asked · How you answered · Gaps and stronger answers · Follow-ups · AI insights |
| `one_on_one` | Summary · Feedback given · Commitments by each side · Career and growth topics · Follow-ups · AI insights |
| `lecture` | Summary · Key concepts · Explanations and sources · Questions to study · AI insights |
| `general` | Summary · Who said what · Open questions with answers · Actions · AI insights |

Therapy rules from the existing prompt stay: no diagnosis, no medical advice, no taking sides, warm, keeps the therapist's own terms. Remove `detectStyle` and `--therapy`; add `--scenario <name>` to force one.

## HTML framework
**The LLM fills JSON; it never writes HTML.** One embedded Swift template renders any scenario from the same `Report` model, so every report looks the same and the models stay simple.

```json
{"schemaVersion":1,"topic":"","scenario":"","createdAt":"","durationSeconds":0,
 "models":{"cheap":"","normal":"","frontier":""},"reviewed":true,"notices":[],
 "sections":[{"id":"","title":"","kind":"prose|bullets|actions|qa|goals|concepts|insights",
   "items":[{"text":"","speaker":"","owner":"","due":"","answer":"","confidence":"sure|unsure",
             "reason":"","source":"ai|transcript","sources":[{"title":"","url":""}]}]}],
 "transcript":[{"start":0,"end":0,"speaker":"","text":"","suggestion":""}]}
```
Rendering rules:
- **File name:** `<yyyyMMdd_HHmmss>_<short-topic>.html`. Topic slug keeps Chinese letters, drops path and shell characters, and is limited to 40 characters.
- Self-contained: inline CSS, no external requests, small inline script only for search and collapse.
- **Escape all model and transcript text.** URLs: only `http`/`https`. A transcript line saying `<script>` must render as text.
- `unsure` items have a visible marker and the reason; AI items are visually separate from what was said.
- Works in light and dark, and prints cleanly. Keep `.txt` and `.md` too, because other tools read them.
- Terminal shows the transcript with time and speaker, then the summary, then the HTML path.

## Done when
- [ ] With fake CLIs: each of the six scenarios renders from recorded JSON; snapshot tests pass; a malformed model reply gets one retry, then a clear failure with the transcript saved.
- [ ] XSS test: script tags and `javascript:` URLs in transcript and model text render inert.
- [ ] Filename test covers Chinese, slashes, emoji and very long topics.
- [ ] A test proves the concept search prompt contains no transcript text or names.
- [ ] **Answer quality with and without regex, full pipeline** (D-19): `scripts/quality-compare.sh --full` runs an invented transcript for each of the six scenarios both ways, on real tiers and frontier review. Check before running that the planned calls fit today's cap of 200 per CLI, and stop rather than exceed it. It records section coverage, facts kept, whether scenario and topic stayed the same, tokens restored correctly, `unsure` items, and a blind frontier-model rating per section. Results go in `dev/evidence/`; the user sees any section rated worse with regex before merge.
- [ ] `--live` on an invented meeting and therapy transcript gives a report the user reads and accepts. **👤 User check.**
- [ ] Verifier passes, deep review findings fixed in this PR.
