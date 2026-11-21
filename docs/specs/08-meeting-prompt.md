# M9: "Transcribe this meeting?" when a call starts

**Goal:** when a meeting app on the user's list starts using the microphone, the desktop app asks once, in a small panel that doesn't take focus, whether to record. Nothing is recorded without a yes. Issue 28; builds on M7's menu bar extra (D-102, D-104).

The mock-up is `dev/tmp/m7-mockups/meeting-prompt-issue28.html` (private artifact with the M7 mock-ups), kept out of the public repo.

## Checked before planning
| Question from the issue | Answer |
|---|---|
| Which API says which process uses the mic | CoreAudio's process objects (macOS 14.2+): `kAudioHardwarePropertyProcessObjectList`, then per process `kAudioProcessPropertyBundleID`, `…PID` and `…IsRunningInput`. A probe run from the shell on this Mac (macOS 26) read them with no permission prompt |
| Which bundle ID shows up | The process that opens the input, often a helper: Chrome's is `com.google.Chrome.helper`, so a catalog ID matches itself or `<id>.<anything>`. Safari's audio runs in `com.apple.WebKit.GPU`, which any WebKit app shares (unsure, see below) |
| The browser tab's site | Needs Automation permission for Chrome or Safari (answer 1) |
| The shell | Can't watch in the background; desktop-only, noted in `docs/parity.md` |
| Calendar | EventKit asks for Calendar access; left out (answer 2) |

## Design
| Part | Design |
|---|---|
| Watching | `CallWatcher` in `MeetingCaptureCore`: reads the process list every second through a `MicUsageSource` protocol (the CoreAudio one is real; tests give a fake and a clock). Pure state per app: a call **starts** when a listed app has held the mic for 3 s (10 s for a browser), and **ends** when it has released it for 10 s, so a mute or a device switch isn't a new call. It reports `callStarted(app)` and `callEnded(app)` only; it never starts capture |
| Which apps | The `MeetingApps` catalog, so detection and the capture source share one list. A desktop-only set (UserDefaults, D-105), "ask for these apps", starts with every catalog app; "Never for Zoom" takes Zoom out of it, not out of capture |
| The panel | A borderless non-activating `NSPanel` at the top right of the screen with the menu bar, in the Terminal Native look (D-101), both themes. `─ MEETING STARTED ─` header; **Transcribe this meeting?**; `Zoom is using the microphone`; a line "Tell the others before you record. Audio stays on this Mac."; buttons **Record** (⌃⌥R), **Not This One**, **Never for Zoom**; a countdown. It closes after 20 s (Settings). It doesn't take focus, so typing in the call isn't interrupted |
| Record | `AppModel.perform(.start)` with that app as the source: `Recorder.prepare(sourceAppID:)` scopes capture to it instead of the first enabled running app. The panel shows "● Recording" for 3 s, and the menu bar shows ● as with any recording |
| Skipped or ignored | Nothing is recorded. The menu bar glyph shows `?` inside the bubble until the call ends (same width, D-104), and its menu says "Zoom call, not recording" with **Record This Call**, so the user can start late |
| Rules | One prompt per call. No prompt while recording or while the window's setup screen is up. A call that starts while another prompt shows replaces nothing: the first one stays |
| Call ends while recording | Only when the recording's source is that app: a second panel, **Call ended. Stop?**, with **Stop** and **Keep Recording**; it stops by itself after 30 s through `perform(.stop)`, so the stop goes through the same path and the `RecordingStopper` rule. Settings can turn this off |
| Settings › Capture | Ask when a meeting starts [on] · apps [all six] · close the prompt after [20 s] · when the call ends [ask, then stop after 30 s / do nothing]. Desktop-only, in UserDefaults |
| Terminal shell | Unchanged. `docs/parity.md` lists the prompt as desktop-only |

## The user's answers (2026-11-21, D-108)
1. **Browsers read the tab's site.** Chrome or Safari ask only when one of their tabs is on a known meeting site (`meet.google.com`, `teams.microsoft.com`, `teams.live.com`, `*.zoom.us`, `*.webex.com`). The URLs are read in-process with `NSAppleScript` (no subprocess) and only their hosts are compared, never stored, logged or sent. macOS asks for Automation permission the first time; if it's refused or fails, the panel falls back to the plain "Chrome is using the microphone". Safari's WebKit GPU process counts as Safari only while Safari runs and a Safari tab is on a meeting site. This brings a `/security-review`.
2. **Calendar events and "record automatically" are left out**, for a follow-up issue.
3. **Keys:** the panel has a **Record** button the user clicks, and while the panel shows, a global ⌃⌥R (Carbon hot key, no permission) records too. The panel never takes focus; there's no ⏎ or esc.
4. **Call ended:** ask, then stop after 30 s; on by default, only for a recording whose source is that app.

## Unsure, to check while building
- Safari: `com.apple.WebKit.GPU` doesn't say which app it serves; answer 1's tab check narrows it, but another WebKit app's call while a Meet tab sits open in Safari would still ask as Safari.
- Whether macOS's Automation question, shown the first time during a call, is acceptable, or Settings should ask ahead.
- Whether a non-activating panel shows over a full-screen call on its Space (`.canJoinAllSpaces`, `.fullScreenAuxiliary`).
- Whether Zoom or Teams stop the input stream on mute, which the 10 s end grace would then treat as the call ending.

## Not in this milestone
Calendar events, automatic recording, Focus-mode rules, anything in the shell.

## Done when
- [ ] `CallWatcher` has tests with a fake source and clock: start after the hold, one prompt per call, a mute shorter than the grace isn't a new call, helpers match, an app taken out of the list asks nothing, no prompt while recording.
- [ ] Record from the panel starts capture scoped to that app through `AppModel.perform`; a test with a stand-in session shows it, and that an early stop is still held until capture is live.
- [ ] A skipped call shows `?` in the menu bar glyph until the call ends, and Record This Call starts a recording; the glyph stays 18 pt wide.
- [ ] Call ended asks and stops after the timeout, only for the recording's own source app; tests cover both apps.
- [ ] Snapshots under `MEETINGCAPTURE_E2E=1` show the prompt, the call-ended panel and the `?` glyph in Phosphor and Paper.
- [ ] `docs/parity.md` lists the prompt as desktop-only; the README mentions it.
- [ ] 👤 The user starts a real call in a listed app, sees the prompt, records from it, skips one, and approves.
- [ ] Browser calls: a test with a fake tab reader shows a meeting host asks, any other host or no tab asks nothing, and a refused Automation falls back to the plain wording. Hosts are matched by suffix on a dot boundary (`evilzoom.us` doesn't match).
- [ ] Verifier, a normal reviewer and `/security-review` (Automation reads browser URLs) pass.
