# M5 — Six designs, then the desktop app

**Goal:** a real Mac app on the latest macOS that follows Apple's design thinking, with the terminal as the superset.

## Step 1: six HTML options, before any app code
Publish six clickable HTML mock-ups for the user to review. **👤 The user picks; the build waits for that.**

They must vary the shape (D-09), and all show the same real-looking screens: idle, recording, processing, report, settings, first-run model download.

| # | Starting idea | Shape |
|---|---|---|
| 1 | Library sidebar, like Voice Memos and Notes | Window |
| 2 | One-click control during calls; notes open separately | Menu bar first |
| 3 | Sidebar library, plus a menu bar recorder | Window + menu bar |
| 4 | Floating glass recording pill above the call | Pill + window |
| 5 | Reading-first report, like Reader or Books | Window |
| 6 | Timeline: transcript and speakers as a time-based document | Window + menu bar |

Principles: Liquid Glass used for controls and navigation only, never for content; system fonts and colours, including Chinese text; hierarchy, clarity and deference; light and dark mode; keyboard shortcuts; recording state always obvious. Check Apple's current Human Interface Guidelines at the time rather than relying on memory.

## Step 2: the app
- SwiftUI, deployment target macOS 26. App target in the same repo, using `MeetingCaptureCore`. Add a `project.yml` or Xcode project only if SwiftPM can't produce a proper `.app`.
- **The Whisper and SpeakerKit models are downloaded, never bundled:** first-run screen with size, progress, cancel and resume.
- Screen Recording and Microphone permissions belong to the app's own identity: Info.plist usage strings, plus a walkthrough screen and a re-check. Local ad-hoc signing is enough for personal use; mention that distribution would need notarization.
- Report opens the same HTML in a `WKWebView`, with JavaScript limited to the report's own script and external navigation sent to the browser.

## Feature parity
The terminal has **every desktop feature, plus finer config.** A test or checklist keeps this true.

| Feature | Desktop | Terminal |
|---|---|---|
| Record, pause, stop, audio source | ✓ | ✓ |
| Library, open report, re-run a step | ✓ | ✓ |
| Rename and merge speakers | ✓ | ✓ |
| Primary CLI, usage display, connection test | ✓ | ✓ |
| Retention days, output folder, Whisper model | ✓ | ✓ |
| Redaction on/off | ✓ | ✓ |
| Per-tier models, reasoning, custom/API profiles, force scenario, language pin, AEC tuning, chunk length | — | ✓ |

## Done when
- [ ] User picked an option; the choice is recorded in `dev/DECISIONS.md`.
- [ ] From a fresh model cache, the app downloads models, records a short clip, and shows the report. Screenshots in `dev/evidence/`.
- [ ] Parity checklist passes.
- [ ] Core logic has no copy in the app target.
- [ ] Verifier passes with screenshots.
