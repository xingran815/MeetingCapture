import AppKit
import MeetingCaptureCore
import SwiftUI

// M7 (D-102): the menu bar extra. It shows whether the app is recording by the glyph's
// shape (D-101), and offers the few actions that matter without the window.

/// The shapes inside the bubble. `asking` (M9) is `?`: a call is on and the user
/// didn't say to record it. Same 18 pt as the others (D-104).
enum MenuBarGlyph: String, CaseIterable {
    case idle, recording, paused, processing, asking

    init(_ activity: AppModel.Activity, unansweredCall: Bool = false) {
        switch activity {
        case .idle: self = unansweredCall ? .asking : .idle
        case .starting, .recording: self = .recording
        case .paused: self = .paused
        case .processing: self = .processing
        }
    }

    /// A template image drawn from `packaging/brand/menubar-*.svg`'s coordinates
    /// (18 pt, y down), so the glyph needs no resource bundle and macOS tints it.
    /// `scripts/make-brand.sh` writes the same shapes as SVG.
    var image: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let bubble = NSBezierPath()
            bubble.move(to: NSPoint(x: 1.6, y: 2))
            bubble.line(to: NSPoint(x: 16.4, y: 2))
            bubble.line(to: NSPoint(x: 16.4, y: 12.4))
            bubble.line(to: NSPoint(x: 7.2, y: 12.4))
            bubble.line(to: NSPoint(x: 3.9, y: 15.8))
            bubble.line(to: NSPoint(x: 3.9, y: 12.4))
            bubble.line(to: NSPoint(x: 1.6, y: 12.4))
            bubble.close()
            bubble.lineWidth = 1.4
            bubble.lineJoinStyle = .miter
            bubble.lineCapStyle = .square
            bubble.stroke()
            switch self {
            case .idle:
                let chevron = NSBezierPath()
                chevron.move(to: NSPoint(x: 4.5, y: 4.7))
                chevron.line(to: NSPoint(x: 7.5, y: 7.2))
                chevron.line(to: NSPoint(x: 4.5, y: 9.7))
                chevron.lineWidth = 1.4
                chevron.lineJoinStyle = .miter
                chevron.lineCapStyle = .square
                chevron.stroke()
                NSRect(x: 8.6, y: 8.8, width: 4.6, height: 1.4).fill()
            case .recording:
                NSBezierPath(ovalIn: NSRect(x: 9 - 2.8, y: 7.2 - 2.8, width: 5.6, height: 5.6)).fill()
            case .paused:
                NSRect(x: 6.8, y: 4.5, width: 1.6, height: 5.4).fill()
                NSRect(x: 9.6, y: 4.5, width: 1.6, height: 5.4).fill()
            case .asking:
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: 6.9, y: 5.6))
                mark.curve(
                    to: NSPoint(x: 9, y: 3.9), controlPoint1: NSPoint(x: 6.9, y: 4.5),
                    controlPoint2: NSPoint(x: 7.8, y: 3.9))
                mark.curve(
                    to: NSPoint(x: 11.1, y: 5.7), controlPoint1: NSPoint(x: 10.2, y: 3.9),
                    controlPoint2: NSPoint(x: 11.1, y: 4.6))
                mark.curve(
                    to: NSPoint(x: 9, y: 7.9), controlPoint1: NSPoint(x: 11.1, y: 7), controlPoint2: NSPoint(x: 9, y: 7)
                )
                mark.line(to: NSPoint(x: 9, y: 8.6))
                mark.lineWidth = 1.4
                mark.lineCapStyle = .square
                mark.stroke()
                NSRect(x: 8.3, y: 9.6, width: 1.4, height: 1.4).fill()
            case .processing:
                NSRect(x: 5, y: 6.5, width: 1.6, height: 1.6).fill()
                NSRect(x: 8.2, y: 6.5, width: 1.6, height: 1.6).fill()
                NSColor.black.withAlphaComponent(0.4).setFill()
                NSRect(x: 11.4, y: 6.5, width: 1.6, height: 1.6).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel
        return image
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "MeetingCapture, ready"
        case .recording: return "MeetingCapture, recording"
        case .paused: return "MeetingCapture, paused"
        case .processing: return "MeetingCapture, working"
        case .asking: return "MeetingCapture, a call is on and not recorded"
        }
    }
}

/// The words the extra and its menu show. Pure, so tests can check every state.
enum MenuBarText {
    /// Beside the glyph, only with `showsText` (Settings › Look, off by default): on a Mac
    /// with a notch the extras share the space right of it, and macOS hides the leftmost
    /// one that doesn't fit. A recording also brings macOS's own screen-recording
    /// indicator, so a wider label made the glyph vanish exactly while recording.
    static func barText(_ activity: AppModel.Activity, showsText: Bool) -> String? {
        showsText ? label(activity) : nil
    }

    /// The clock while recording or paused, `3/6` while working.
    static func label(_ activity: AppModel.Activity) -> String? {
        switch activity {
        case .idle, .starting: return nil
        case .recording(let t), .paused(let t): return clock(t)
        case .processing(let step, let of, _): return "\(step)/\(of)"
        }
    }

    /// The menu's first line. `unansweredCall` is the app's name while `?` shows.
    static func status(_ activity: AppModel.Activity, unansweredCall: String? = nil) -> String {
        switch activity {
        case .idle: return unansweredCall.map { "? \($0) call, not recording" } ?? "✓ Ready"
        case .starting: return "● Starting…"
        case .recording(let t): return "● Recording \(clock(t))"
        case .paused(let t): return "‖ Paused at \(clock(t))"
        case .processing(let step, let of, let name): return "··· \(name) \(step)/\(of)"
        }
    }

    /// `12:04`, or `1:02:03` past an hour.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// One row of the menu. The view draws these; tests read them.
struct MenuBarItem: Identifiable, Equatable {
    enum Action: Equatable {
        case command(RecordingCommand)
        /// Record This Call: the call the user skipped or let pass (M9).
        case recordCall
        case openLastReport
        case openWindow
        case settings
        case quit
    }

    var title: String
    var keys: String?
    var enabled: Bool
    var action: Action
    var id: String { title }
    var isRecordingCommand: Bool {
        switch action {
        case .command, .recordCall: return true
        default: return false
        }
    }

    /// Start, or Pause/Resume, Stop and Abort; then the last report, Open, Settings and Quit.
    @MainActor
    static func items(for model: AppModel) -> [MenuBarItem] {
        items(
            recording: model.phase != .idle, paused: model.paused,
            enabled: { model.canPerform($0) },
            lastReport: model.lastReport.map { $0.topic ?? AppModel.title(for: $0.base, short: true) },
            unansweredCall: model.meetingPrompt.unanswered != nil)
    }

    static func items(
        recording: Bool, paused: Bool, enabled: (RecordingCommand) -> Bool, lastReport: String?,
        unansweredCall: Bool = false
    ) -> [MenuBarItem] {
        var items: [MenuBarItem] = []
        if !recording, unansweredCall {
            items.append(
                MenuBarItem(title: "Record This Call", keys: nil, enabled: enabled(.start), action: .recordCall))
        }
        if !recording {
            items.append(
                MenuBarItem(title: "Start Recording", keys: "⌘R", enabled: enabled(.start), action: .command(.start)))
        } else {
            items.append(
                MenuBarItem(
                    title: paused ? "Resume" : "Pause", keys: "⇧⌘P", enabled: enabled(.pauseResume),
                    action: .command(.pauseResume)))
            items.append(MenuBarItem(title: "Stop", keys: "⌘.", enabled: enabled(.stop), action: .command(.stop)))
            items.append(
                MenuBarItem(title: "Abort…", keys: "⌥⌘.", enabled: enabled(.abort), action: .command(.abort)))
        }
        if let lastReport {
            items.append(MenuBarItem(title: "↳ " + lastReport, keys: nil, enabled: true, action: .openLastReport))
        }
        items.append(MenuBarItem(title: "Open MeetingCapture", keys: nil, enabled: true, action: .openWindow))
        items.append(MenuBarItem(title: "Settings…", keys: "⌘,", enabled: true, action: .settings))
        items.append(MenuBarItem(title: "Quit MeetingCapture", keys: "⌘Q", enabled: true, action: .quit))
        return items
    }
}

/// What sits in the menu bar: the glyph, and the clock or step count when there is one.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MenuBarPreference.showsTextKey) private var showsText = false

    var body: some View {
        let activity = model.activity
        let glyph = MenuBarGlyph(activity, unansweredCall: model.meetingPrompt.unanswered != nil)
        HStack(spacing: 4) {
            Image(nsImage: glyph.image)
            if let text = MenuBarText.barText(activity, showsText: showsText) {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glyph.accessibilityLabel)
        .accessibilityValue(MenuBarText.label(activity) ?? "")
    }
}

/// The extra's menu: a status line, the source, the actions.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(MenuBarText.status(model.activity, unansweredCall: model.meetingPrompt.unanswered?.appName))
        Text("Source: " + source)
        Divider()
        let items = MenuBarItem.items(for: model)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            // A line between the recording actions and the rest.
            if index > 0, items[index - 1].isRecordingCommand, !item.isRecordingCommand { Divider() }
            Button(item.title) { run(item.action) }
                .disabled(!item.enabled)
                .modifier(Shortcut(keys: item.keys))
        }
    }

    private var source: String {
        if model.phase != .idle, !model.sourceLabel.isEmpty { return model.sourceLabel }
        return model.settings.captureAllAudio ? "all system audio" : "meeting apps, detected"
    }

    private func run(_ action: MenuBarItem.Action) {
        switch action {
        case .command(let command):
            model.perform(command)
        case .recordCall:
            model.meetingPrompt.recordUnanswered()
        case .openLastReport:
            if let last = model.lastReport {
                model.showsJob = false
                model.selection = last.id
            }
            bringWindow()
        case .openWindow:
            bringWindow()
        case .settings:
            NSApp.activate()
            openSettings()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func bringWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }

    /// Shows the key beside the item. The keys act through the app's own menus; here
    /// they're a reminder.
    private struct Shortcut: ViewModifier {
        let keys: String?
        func body(content: Content) -> some View {
            switch keys {
            case "⌘R": content.keyboardShortcut("r", modifiers: .command)
            case "⇧⌘P": content.keyboardShortcut("p", modifiers: [.command, .shift])
            case "⌘.": content.keyboardShortcut(".", modifiers: .command)
            case "⌥⌘.": content.keyboardShortcut(".", modifiers: [.command, .option])
            case "⌘,": content.keyboardShortcut(",", modifiers: .command)
            case "⌘Q": content.keyboardShortcut("q", modifiers: .command)
            default: content
            }
        }
    }
}

enum MenuBarPreference {
    /// Desktop-only (UserDefaults). Off hides the extra; the app still keeps running when
    /// its window closes, as before M7, and the Dock icon brings the window back.
    static let key = "showsMenuBarExtra"
    /// Desktop-only: the clock or step count beside the glyph. Off by default (see
    /// `MenuBarText.barText`); the menu's first line always has it.
    static let showsTextKey = "menuBarShowsText"
}
