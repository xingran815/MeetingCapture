import AppKit
import Carbon.HIToolbox
import MeetingCaptureCore
import Observation
import SwiftUI

// M9 (issue 28, D-108): "Transcribe this meeting?" when a listed meeting app starts a
// call. Nothing is recorded without a yes: a click on Record, or ⌃⌥R while the panel shows.

/// Desktop-only settings (UserDefaults, D-105): the terminal can't watch for calls.
enum MeetingPromptPreference {
    static let askKey = "meetingPromptAsks"
    /// Apps the user turned off ("Never for Zoom"). Kept as the ones left out, so an app
    /// added to the catalog later asks by default.
    static let skippedAppsKey = "meetingPromptSkippedApps"
    static let timeoutKey = "meetingPromptTimeout"
    static let stopAtCallEndKey = "meetingPromptStopsAtCallEnd"
    static let timeouts = [10, 20, 30, 60]
    /// How long "Call ended. Stop?" waits before it stops.
    static let callEndedSeconds: TimeInterval = 30

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [askKey: true, timeoutKey: 20, stopAtCallEndKey: true])
    }

    static func skippedApps(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.string(forKey: skippedAppsKey) ?? "").split(separator: ",").map(String.init))
    }

    static func setSkipped(_ ids: Set<String>, _ defaults: UserDefaults = .standard) {
        defaults.set(ids.sorted().joined(separator: ","), forKey: skippedAppsKey)
    }
}

/// Reads a browser's tab addresses to see whether one is on a meeting site. Tests give a fake.
@MainActor
protocol BrowserTabReading {
    func check(appID: String, done: @escaping @MainActor (TabCheck) -> Void)
}

/// Asks Chrome or Safari for their tabs' addresses through Apple Events, in this process
/// (no `osascript`). macOS asks the user for Automation permission the first time. Only
/// the hosts are compared (`MeetingSites`); the addresses are dropped at once and never
/// logged, kept or sent.
@MainActor
final class AppleScriptBrowserTabs: BrowserTabReading {
    private let queue = DispatchQueue(label: "MeetingCapture.browserTabs")

    nonisolated static func bundleID(for appID: String) -> String? {
        switch appID {
        case "chrome": return "com.google.Chrome"
        case "safari": return "com.apple.Safari"
        default: return nil
        }
    }

    /// `is running` inside the script too: a browser that quit after the check would
    /// otherwise be launched by `tell` (M9 review).
    nonisolated static func script(for appID: String) -> String? {
        guard let bundle = bundleID(for: appID) else { return nil }
        return """
            if application id "\(bundle)" is running then
                tell application id "\(bundle)" to get URL of every tab of every window
            end if
            """
    }

    func check(appID: String, done: @escaping @MainActor (TabCheck) -> Void) {
        guard let source = Self.script(for: appID), let bundle = Self.bundleID(for: appID) else {
            done(.unknown)
            return
        }
        // The permission question waits for the user's answer, so it's asked off the
        // main thread. `NSAppleScript` itself runs on the main thread, as Apple asks; once
        // permission is settled it returns at once (M9 review).
        queue.async {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else {
                Task { @MainActor in done(.notMeeting) }
                return
            }
            let allowed = Self.automationAllowed(bundle)
            Task { @MainActor in
                guard allowed else {
                    done(.unknown)
                    return
                }
                done(Self.run(source))
            }
        }
    }

    /// macOS's Automation permission for this browser, asking the user the first time.
    nonisolated private static func automationAllowed(_ bundle: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
        return status == noErr
    }

    private static func run(_ source: String) -> TabCheck {
        guard let script = NSAppleScript(source: source) else { return .unknown }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        guard error == nil else { return .unknown }
        var urls: [String] = []
        collect(output, into: &urls)
        if let host = MeetingSites.meetingHost(in: urls) { return .meeting(host: host) }
        return .notMeeting
    }

    nonisolated private static func collect(_ descriptor: NSAppleEventDescriptor, into urls: inout [String]) {
        if descriptor.numberOfItems > 0 {
            for i in 1...descriptor.numberOfItems {
                if let item = descriptor.atIndex(i) { collect(item, into: &urls) }
            }
        } else if let string = descriptor.stringValue {
            urls.append(string)
        }
    }
}

/// ⌃⌥R while the panel shows. A Carbon hot key needs no permission, unlike watching
/// every key press. Registered only while asking, so it never shadows another app longer.
@MainActor
final class PromptHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private static weak var current: PromptHotKey?

    func register(_ action: @escaping @MainActor () -> Void) {
        unregister()
        self.action = action
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { PromptHotKey.current?.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4D43_5250), id: 1)  // "MCRP"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        action = nil
    }
}

/// The prompt's state. `tick()` runs once a second while watching; tests call
/// `handle(_:)` and `tick()` with their own clock instead.
@MainActor
@Observable
final class MeetingPromptController {
    enum Panel: Equatable {
        /// "Transcribe this meeting?" until `closesAt`.
        case ask(DetectedCall, closesAt: Date)
        /// "● Recording" for a moment after a yes.
        case recording(DetectedCall, closesAt: Date)
        /// "Call ended. Stop?" — stops at `stopsAt`.
        case callEnded(DetectedCall, stopsAt: Date)

        var call: DetectedCall {
            switch self {
            case .ask(let c, _), .recording(let c, _), .callEnded(let c, _): return c
            }
        }
    }

    weak var model: AppModel?
    /// The panel to show, or nil. The window follows it (`onPanelChange`).
    private(set) var panel: Panel? {
        didSet { if panel != oldValue { onPanelChange?(panel) } }
    }
    /// A call the user skipped or let pass, until it ends: the `?` in the menu bar.
    private(set) var unanswered: DetectedCall?

    @ObservationIgnored var onPanelChange: ((Panel?) -> Void)?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var micSource: MicUsageSource = CoreAudioMicUsage()
    @ObservationIgnored var tabs: BrowserTabReading = AppleScriptBrowserTabs()
    @ObservationIgnored var runningApps: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    @ObservationIgnored let watcher = CallWatcher()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let hotKey = PromptHotKey()
    /// Browsers whose tabs are being read; a check isn't queued twice while macOS's
    /// Automation question waits for an answer (M9 review).
    @ObservationIgnored private(set) var tabChecksInFlight: Set<String> = []
    /// The recording "Call ended. Stop?" was raised for, so it never stops a newer one.
    @ObservationIgnored private var callEndedSession: ObjectIdentifier?

    init() {}

    var asksAtCallStart: Bool { defaults.bool(forKey: MeetingPromptPreference.askKey) }
    var stopsAtCallEnd: Bool { defaults.bool(forKey: MeetingPromptPreference.stopAtCallEndKey) }
    var timeout: TimeInterval {
        let t = defaults.integer(forKey: MeetingPromptPreference.timeoutKey)
        return TimeInterval(t > 0 ? t : 20)
    }

    /// The apps that ask, from Settings.
    var askingApps: Set<String> {
        Set(MeetingAppChoice.all.map(\.id)).subtracting(MeetingPromptPreference.skippedApps(defaults))
    }

    /// Starts the once-a-second look at the mic. Not under the E2E demo, which draws
    /// its states without watching.
    func startWatching() {
        MeetingPromptPreference.register(defaults)
        guard timer == nil, DemoState.requested == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Reads who holds the mic and handles what changed.
    func poll() {
        watcher.appIDs = watchedApps
        // With nothing watched, still update with no users: the watcher ends the calls of
        // apps it no longer watches, which clears a `?` (M9 review). The mic isn't read.
        let watching = !watcher.appIDs.isEmpty
        let events = watcher.update(
            now: now(), users: watching ? micSource.micUsers() : [], running: watching ? runningApps() : [])
        handle(events)
        tick()
    }

    /// The prompt's apps, plus the one being recorded so its call end is seen.
    var watchedApps: Set<String> {
        var apps = asksAtCallStart ? askingApps : []
        if let model, model.phase != .idle, stopsAtCallEnd, let source = model.recordingSourceAppID {
            apps.insert(source)
        }
        return apps
    }

    func handle(_ events: [CallEvent]) {
        for event in events {
            switch event {
            case .checkTabs(let appID):
                guard !tabChecksInFlight.contains(appID) else { continue }
                tabChecksInFlight.insert(appID)
                tabs.check(appID: appID) { [weak self] result in
                    self?.tabChecksInFlight.remove(appID)
                    self?.watcher.tabsChecked(appID: appID, result)
                }
            case .started(let call):
                callStarted(call)
            case .ended(let call):
                callEnded(call)
            }
        }
    }

    private func callStarted(_ call: DetectedCall) {
        // The recorded app's call came back (a dropped connection, a rejoin): don't stop it.
        if case .callEnded(let ended, _) = panel, ended.appID == call.appID { close() }
        // One prompt per call: a call seen while recording, or while another prompt
        // shows, is never asked about later.
        guard let model, asksAtCallStart, askingApps.contains(call.appID) else { return }
        guard model.phase == .idle, !model.needsSetup, panel == nil else { return }
        panel = .ask(call, closesAt: now().addingTimeInterval(timeout))
        hotKey.register { [weak self] in self?.record() }
    }

    private func callEnded(_ call: DetectedCall) {
        if unanswered?.appID == call.appID { unanswered = nil }
        if let panel, panel.call.appID == call.appID, case .ask = panel { close() }
        guard let model, stopsAtCallEnd, model.phase != .idle, model.recordingSourceAppID == call.appID else {
            return
        }
        if case .callEnded = panel { return }
        callEndedSession = model.currentSession.map(ObjectIdentifier.init)
        panel = .callEnded(call, stopsAt: now().addingTimeInterval(MeetingPromptPreference.callEndedSeconds))
    }

    /// Timeouts, and panels the app's own state made pointless.
    func tick() {
        let recording = model.map { $0.phase != .idle } ?? false
        // Recorded another way: the call is answered.
        if recording, unanswered != nil { unanswered = nil }
        guard let panel else { return }
        let t = now()
        switch panel {
        case .ask(let call, let closesAt):
            if recording {
                // Started another way (the window, the menu bar): the question is answered.
                close()
            } else if t >= closesAt {
                unanswered = call
                close()
            }
        case .recording(_, let closesAt):
            if t >= closesAt { close() }
        case .callEnded(_, let stopsAt):
            if !recording || !isCallEndedSession {
                close()
            } else if t >= stopsAt {
                close()
                model?.perform(.stop)
            }
        }
    }

    // MARK: The panel's buttons

    /// Record: capture starts with that app as the source (`AppModel.perform`).
    func record() {
        guard case .ask(let call, _) = panel, let model else { return }
        guard model.canPerform(.start) else {
            // Keep the late start in the menu bar (M9 review).
            unanswered = call
            close()
            return
        }
        unanswered = nil
        model.perform(.start, source: call.appID)
        guard model.phase != .idle else {
            // Couldn't prepare the recording; the window says why (`recordError`).
            close()
            return
        }
        panel = .recording(call, closesAt: now().addingTimeInterval(3))
        hotKey.unregister()
    }

    /// Record This Call, from the menu bar while `?` shows.
    func recordUnanswered() {
        guard let call = unanswered, let model, model.canPerform(.start) else { return }
        unanswered = nil
        model.perform(.start, source: call.appID)
    }

    /// Not This One: nothing is recorded; the menu bar keeps `?` until the call ends.
    func skip() {
        guard case .ask(let call, _) = panel else { return }
        unanswered = call
        close()
    }

    /// Never for this app: takes it out of the prompt's list, not out of capture.
    func never() {
        guard case .ask(let call, _) = panel else { return }
        var skipped = MeetingPromptPreference.skippedApps(defaults)
        skipped.insert(call.appID)
        MeetingPromptPreference.setSkipped(skipped, defaults)
        unanswered = nil
        close()
    }

    /// Stop, on "Call ended. Stop?".
    func stopNow() {
        guard case .callEnded = panel else { return }
        let same = isCallEndedSession
        close()
        if same { model?.perform(.stop) }
    }

    /// True while the recording is still the one the call-ended question was raised for.
    private var isCallEndedSession: Bool {
        guard let id = callEndedSession, let session = model?.currentSession else { return false }
        return ObjectIdentifier(session) == id
    }

    /// Keep Recording, on "Call ended. Stop?".
    func keepRecording() {
        guard case .callEnded = panel else { return }
        close()
    }

    private func close() {
        callEndedSession = nil
        panel = nil
        hotKey.unregister()
    }

    /// Test-only (the E2E demo): shows a panel without a call.
    func showDemo(_ panel: Panel?, unanswered: DetectedCall? = nil) {
        self.panel = panel
        self.unanswered = unanswered
    }
}

// MARK: The window

/// The floating panel at the top right. It never becomes key, so typing in the call
/// carries on; buttons still take clicks.
@MainActor
final class MeetingPromptWindow {
    private var panel: NSPanel?
    private weak var controller: MeetingPromptController?

    init(controller: MeetingPromptController) {
        self.controller = controller
        controller.onPanelChange = { [weak self] state in self?.show(state) }
    }

    private func show(_ state: MeetingPromptController.Panel?) {
        guard let state, let controller else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let host = NSHostingView(
            rootView: MeetingPromptView(state: state, controller: controller).terminalThemed())
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        // The screen with the menu bar, where the extra's `?` is.
        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - host.fittingSize.width - 16, y: frame.maxY - 12))
        }
        panel.orderFrontRegardless()
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        return panel
    }
}

/// The words on the panel. Pure, so tests can read them.
enum MeetingPromptText {
    static func header(_ state: MeetingPromptController.Panel) -> String {
        switch state {
        case .ask: return "MEETING STARTED"
        case .recording: return "RECORDING"
        case .callEnded: return "CALL ENDED"
        }
    }

    static func question(_ state: MeetingPromptController.Panel) -> String {
        switch state {
        case .ask: return "Transcribe this meeting?"
        case .recording: return "● Recording"
        case .callEnded: return "Call ended. Stop?"
        }
    }

    static func detail(_ state: MeetingPromptController.Panel) -> String {
        switch state {
        case .ask(let call, _):
            return call.isBrowser && call.site == nil
                ? call.sourceLine + " (its tabs couldn't be checked)" : call.sourceLine
        case .recording(let call, _): return "Source: " + call.appName
        case .callEnded(let call, _): return call.appName + " released the microphone."
        }
    }

    static let reminder = "Tell the others before you record. Audio stays on this Mac."

    /// "closes in 12 s", "stops in 30 s".
    static func countdown(_ state: MeetingPromptController.Panel, now: Date) -> String? {
        switch state {
        case .ask(_, let at): return "closes in \(max(0, Int(at.timeIntervalSince(now).rounded(.up)))) s"
        case .recording: return nil
        case .callEnded(_, let at): return "stops in \(max(0, Int(at.timeIntervalSince(now).rounded(.up)))) s"
        }
    }
}

struct MeetingPromptView: View {
    let state: MeetingPromptController.Panel
    let controller: MeetingPromptController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("─ " + MeetingPromptText.header(state) + " ─")
                    .font(.mono(11.5, .semibold))
                    .foregroundStyle(isRecording ? theme.rec : theme.amber)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let text = MeetingPromptText.countdown(state, now: context.date) {
                        Text(text).font(.mono(11)).foregroundStyle(theme.faint)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(theme.line)
            VStack(alignment: .leading, spacing: 10) {
                Text(MeetingPromptText.question(state)).font(.mono(16, .bold)).foregroundStyle(theme.text)
                Text(MeetingPromptText.detail(state)).font(.mono(12)).foregroundStyle(theme.dim)
                if case .ask = state {
                    Text(MeetingPromptText.reminder).font(.mono(11.5)).foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
            .padding(12)
        }
        .frame(width: 380, alignment: .leading)
        .background(theme.ground)
        .overlay(Rectangle().stroke(theme.line2, lineWidth: 1))
    }

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    @ViewBuilder private var buttons: some View {
        switch state {
        case .ask(let call, _):
            HStack(spacing: 6) {
                PromptButton(title: "● Record", keys: "⌃⌥R", primary: true) { controller.record() }
                PromptButton(title: "Not This One") { controller.skip() }
                PromptButton(title: "Never for " + call.appName) { controller.never() }
            }
        case .recording:
            EmptyView()
        case .callEnded:
            HStack(spacing: 6) {
                PromptButton(title: "■ Stop", primary: true) { controller.stopNow() }
                PromptButton(title: "Keep Recording") { controller.keepRecording() }
            }
        }
    }
}

private struct PromptButton: View {
    let title: String
    var keys: String?
    var primary = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.mono(12, primary ? .bold : .medium))
                if let keys { Text(keys).font(.mono(10.5)).opacity(0.8) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(primary ? theme.ground : theme.text)
            .background(primary ? theme.accent : theme.ground)
            .overlay(Rectangle().stroke(primary ? theme.accent : theme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(title)
    }
}
