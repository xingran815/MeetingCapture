# M5 step 1: Apple HIG notes and the six mock-ups

Read 2026-11-07 from Apple's live Human Interface Guidelines (the pages are rendered in the browser, so the text came from their JSON data at `developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`). Pages: materials, sidebars, toolbars, the-menu-bar, windows, panels, typography, color, dark-mode, progress-indicators, privacy, keyboards. No page showed a change date.

## Rules the mock-ups follow

| Topic | HIG says | In the mock-ups |
|---|---|---|
| Liquid Glass | A layer for controls and navigation that floats above content. **Don't use it in the content layer**; use it sparingly; regular variant for sidebars, popovers and text-heavy parts | Glass only on sidebar, toolbar groups, menus, banners, the pill. Reports, lists and cards are opaque |
| Glass colour | Colour only where it truly helps, such as status or the primary action, on the background, not on many controls | Red tint only on Record/Stop; one prominent action per toolbar |
| Sidebars (macOS) | Float above content; let people hide it; no critical actions at the bottom; at most two levels | Options 1 and 3: floating inset sidebar, nothing important at the bottom |
| Toolbars | Few items; symbols without borders; one `.prominent` action, on the trailing side; title under 15 characters, not the app name; every toolbar item also in the menu bar | Record/Stop trailing; titles are the recording's name |
| Menu bar extras | Use a symbol; **show a menu, not a popover**, unless it's too complex; the user decides whether it shows (a setting, offered at setup); don't rely on it, offer a Dock menu too | Options 2, 3, 6: a menu; "Show recorder in the menu bar" in Settings; option 2's first run mentions the Dock menu |
| Panels | Can use a dark translucent HUD style; title bar; no minimize | Option 4's pill is a HUD-style panel |
| Typography | SF Pro; macOS has no Dynamic Type; use the built-in text styles (body 13 pt) | System font stack with PingFang SC for Chinese; New York (`ui-serif`) for option 5's reading view |
| Colour, dark mode | System colours; supply light, dark and increased-contrast variants | Light and Dark switch on every option; text colours chosen for 4.5:1 |
| Progress | Determinate when possible; even pacing; let people cancel; offer Pause where cancelling loses work; say when stopping loses progress | Model download: bar, Pause, Cancel, and "the part already downloaded is kept" |
| Privacy | A custom screen may explain before the system prompt; ask in context | First run explains Microphone and Screen & System Audio Recording before macOS asks, with Check again |
| Keyboard | Standard shortcuts keep their meaning (⌘, Settings, ⌘Q, ⌘W…) | Record ⌘R, Pause ⇧⌘P, Stop ⌘., Settings ⌘,, Library ⌘L |

Not verified: the exact macOS 26 text-style sizes (the typography table didn't come through the JSON), and whether ⌘. for Stop clashes with anything in a SwiftUI app. Check both while building.

## The mock-ups

Published as one private Design canvas (link in `dev/NOW.md`); the sources are in `dev/evidence/m5-mockups/`. Each option is one artboard with a bar on top to switch screens (Idle, Recording, Processing, Report, Settings, First run) and Light/Dark. Report, Settings and First run are shared pieces imported into every option, so the shapes differ only where the spec's table says they should. Data is invented.

| # | Shape | Idea |
|---|---|---|
| 1 | Window | Two-column library sidebar, record from the toolbar, big record button when idle |
| 2 | Menu bar first | Menu from a menu bar extra; red timer in the menu bar while recording; each report opens in its own window with a "Report ready" notification |
| 3 | Window + menu bar | Three columns (report types, list, detail) and a menu bar recorder for calls |
| 4 | Pill + window | A floating glass pill above the call: record, meters, pause, stop; shrinks when idle |
| 5 | Window | Reading first: a list of reports to read, serif reading view with contents; recording sits in the toolbar |
| 6 | Window + menu bar | Timeline: speaker lanes, report points pinned to when they were said, transcript beside them |
