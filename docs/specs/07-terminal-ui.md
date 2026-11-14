# M7: the Terminal Native UI, a menu bar extra and a logo

**Goal:** the desktop app looks and feels like the terminal it grew from. A menu bar extra shows at a glance whether the app is recording and offers minimal control. The app gets its own logo. Decisions: D-101, D-102.

Mock-ups are not in the repo (the repo is public). They're in a private artifact, https://claude.ai/artifact/6VmJqJ96EW555iCdLGwJ7y, with a local copy in `dev/tmp/m7-mockups/`, which is gitignored:
- `round1-directions/c02-terminal.html` is the chosen direction. Its logo was replaced; the other nine directions sit beside it.
- `logos-round2.html` shows the chosen logo, card 2 "Prompt Bubble".
- `meeting-prompt-issue28.html` belongs to issue 28, which comes after this milestone.

Brand sources are in `packaging/brand/` and are made by `scripts/make-brand.sh`.

## Design
| Part | Design |
|---|---|
| Look | Monospace throughout; box-drawing borders with a label set into the top border (`─ LABEL ─`); `##` section heads; key hints (`kbd`) on every action; block-character level meters; states spelled out in words (`● REC`, `‖ PAUSED`, `3/6 transcribing`). No colour-only signal |
| Themes | **Phosphor** (dark: `#0a0d0b` ground, `#d6f5df` text, `#4dff9a` accent) and **Paper** (light: `#f2eee2` ground, `#1b241d` text, `#0b6a33` accent). They follow the system appearance; Settings can pin one. Red (`#ff5c5c` / `#a8161b`) appears only while recording; amber (`#ffb340` / `#7a4a00`) for paused and warnings. Body text reaches 4.5:1 in both |
| Type | SF Mono (system `.monospaced`), so no font is bundled. The mock-ups used JetBrains Mono; bundling it (OFL) is the fallback if SF Mono doesn't feel right at the 👤 check |
| Logo | "Prompt Bubble": a square-cornered speech bubble (the meeting) holding `>_` (the terminal). App icon `packaging/AppIcon.icns` from `packaging/brand/app-icon.svg`; `build-app.sh` already copies it in |
| Menu bar extra | SwiftUI `MenuBarExtra`, on by default, with a Settings switch to hide it (HIG: the user decides). The glyph is a template image, and its state is in the shape: idle `>_`, recording ●, paused ‖, processing ··· inside the bubble. Beside the glyph: `12:04` while recording or paused (the paused one frozen), `3/6` while processing |
| Its menu | Status line (Ready · Recording 12:04 · Paused · Transcribing 3/6), Start ⌘R or Pause ⇧⌘P / Resume and Stop ⌘., the detected source, the last report (opens it), Open MeetingCapture, Settings…, Quit. A menu, not a popover, unless the status line can't be drawn in one |
| Window | Same features and layout as M5 (D-91): library sidebar with groups, report view, Record idle / Recording / Processing screens, sheets and Settings, restyled. Recording keeps D-91's one calm waveform, drawn in the new style. A status line at the bottom of the window shows the state and the keys, like the mock-up's vim-style line |
| Closing the window | The app keeps running while the menu bar extra is on, so a recording survives closing the window. ⌘Q keeps its existing "Quit during a recording?" guard |
| Terminal shell | Unchanged apart from the mark: the banner may show `>_` in a bubble drawn with box characters. It needs no new features, and the parity list gains a "desktop only" note for the menu bar extra |

## Not in this milestone
- The "Transcribe this meeting?" prompt when a call starts is **issue 28**, built after M7. It builds on the menu bar extra.
- Any change to capture, transcription or reports.

## Unsure, to check while building
- Whether a `MenuBarExtra` label can carry a red pill behind the glyph. Template rendering may strip colour; if it does, the shape and the timer text carry the state alone. That's acceptable, because the shape was designed for it.
- How SwiftUI's `.menu` style draws a status line with a running timer, and whether it updates while the menu is open.
- Whether a SwiftPM target can ship the template glyphs as resources, or whether they should be drawn as SwiftUI `Path`s from the same coordinates.

## Done when
- [ ] The app uses both themes; a test or snapshot under `MEETINGCAPTURE_E2E=1` shows the library, a report, Recording and Processing in Phosphor and Paper, with invented data.
- [ ] The menu bar extra shows the four states by shape. Start, Pause/Resume and Stop from its menu drive the same `AppModel` calls as the toolbar and keys, and a test proves an early Stop from the menu is held until capture is live (the `RecordingStopper.arm()` rule).
- [ ] Closing the window during a recording doesn't stop it; the menu bar extra still shows REC and can stop it.
- [ ] `build-app.sh` produces an app with the new icon; `scripts/make-brand.sh` rebuilds the icon from its SVG.
- [ ] `docs/parity.md` lists the menu bar extra as desktop-only, and the README shows the new look.
- [ ] 👤 The user looks at the app in both themes and the menu bar in its four states, and approves.
- [ ] Verifier and a normal reviewer pass. A deep review isn't needed unless the menu bar controls change the recording code, rather than only calling `AppModel`.
