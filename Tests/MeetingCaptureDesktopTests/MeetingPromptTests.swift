import XCTest

@testable import MeetingCaptureCore
@testable import MeetingCaptureDesktop

/// A mic that reports whoever the test says.
final class FakeMic: MicUsageSource {
    var users: [MicUser] = []
    func micUsers() -> [MicUser] { users }
}

/// A tab reader that answers at once, or holds the answer until the test lets it go.
@MainActor
final class FakeTabs: BrowserTabReading {
    var answer: TabCheck = .unknown
    /// When true the answer is kept until `release()`.
    var holds = false
    private(set) var asked: [String] = []
    private var pending: [@MainActor (TabCheck) -> Void] = []
    func check(appID: String, done: @escaping @MainActor (TabCheck) -> Void) {
        asked.append(appID)
        if holds { pending.append(done) } else { done(answer) }
    }
    func release() {
        let waiting = pending
        pending = []
        for done in waiting { done(answer) }
    }
}

class MeetingPromptTestCase: AppModelTestCase {
    var prompt: MeetingPromptController!
    var defaults: UserDefaults!
    var mic: FakeMic!
    var tabs: FakeTabs!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var suite = ""

    let zoomCall = DetectedCall(appID: "zoom", appLabel: "Zoom", site: nil, isBrowser: false)
    let teamsCall = DetectedCall(appID: "teams", appLabel: "Microsoft Teams", site: nil, isBrowser: false)

    override func setUp() async throws {
        try await super.setUp()
        suite = "mc-prompt-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        MeetingPromptPreference.register(defaults)
        mic = FakeMic()
        tabs = FakeTabs()
        prompt = model.meetingPrompt
        prompt.defaults = defaults
        prompt.micSource = mic
        prompt.tabs = tabs
        prompt.runningApps = { [] }
        prompt.now = { [unowned self] in self.clock }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        prompt = nil
        try await super.tearDown()
    }

    func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    func ask(_ call: DetectedCall) {
        prompt.handle([.started(call)])
    }

    /// Yes on the panel, capture live, recording phase reached.
    func recordFromPanel(_ call: DetectedCall) {
        ask(call)
        prompt.record()
        wait("start called") { self.session.startCalls == 1 }
        session.goLive()
        wait("recording") { self.model.phase == .recording }
    }
}

final class MeetingPromptControllerTests: MeetingPromptTestCase {
    // MARK: Asking

    func testAStartedCallShowsTheAskPanelWithTheConfiguredTimeout() {
        defaults.set(30, forKey: MeetingPromptPreference.timeoutKey)
        ask(zoomCall)
        XCTAssertEqual(prompt.panel, .ask(zoomCall, closesAt: clock.addingTimeInterval(30)))
        XCTAssertNil(prompt.unanswered)
        XCTAssertEqual(session.startCalls, 0, "asking never records")
        XCTAssertEqual(model.phase, .idle)
    }

    func testRecordStartsCaptureScopedToThatAppAndShowsRecording() {
        ask(zoomCall)
        prompt.record()
        XCTAssertEqual(model.recordingSourceAppID, "zoom")
        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(prompt.panel, .recording(zoomCall, closesAt: clock.addingTimeInterval(3)))
        wait("start called") { self.session.startCalls == 1 }
        session.goLive()
        wait("recording") { self.model.phase == .recording }
        XCTAssertEqual(model.recordingSourceAppID, "zoom")
        advance(3)
        prompt.tick()
        XCTAssertNil(prompt.panel, "the recording note closes after 3 s")
        XCTAssertEqual(model.phase, .recording, "closing the note never stops the recording")
    }

    func testAnEarlyStopAfterRecordFromThePanelIsHeldUntilCaptureIsLive() {
        ask(zoomCall)
        prompt.record()
        wait("start called") { self.session.startCalls == 1 }
        model.perform(.stop)
        XCTAssertEqual(session.stopCalls, 1)
        settle(0.4)
        XCTAssertEqual(session.endedCount, 0, "stop must wait for capture to be live")
        XCTAssertEqual(model.phase, .starting)
        session.goLive()
        wait("idle") { self.model.phase == .idle }
        XCTAssertEqual(session.endedCount, 1)
        XCTAssertEqual(finished.count, 1)
    }

    func testTimeoutLeavesTheCallUnansweredAndClosesThePanel() {
        ask(zoomCall)
        advance(19)
        prompt.tick()
        XCTAssertNotNil(prompt.panel)
        XCTAssertNil(prompt.unanswered)
        advance(1)
        prompt.tick()
        XCTAssertNil(prompt.panel)
        XCTAssertEqual(prompt.unanswered, zoomCall)
        XCTAssertEqual(session.startCalls, 0)
    }

    func testSkipLeavesTheCallUnanswered() {
        ask(zoomCall)
        prompt.skip()
        XCTAssertNil(prompt.panel)
        XCTAssertEqual(prompt.unanswered, zoomCall)
        XCTAssertEqual(session.startCalls, 0)
    }

    func testNeverAddsTheAppToTheSkippedListAndTheNextCallAsksNothing() {
        ask(zoomCall)
        prompt.never()
        XCTAssertNil(prompt.panel)
        XCTAssertNil(prompt.unanswered)
        XCTAssertEqual(MeetingPromptPreference.skippedApps(defaults), ["zoom"])
        XCTAssertFalse(prompt.askingApps.contains("zoom"))
        XCTAssertTrue(prompt.askingApps.contains("teams"))
        ask(zoomCall)
        XCTAssertNil(prompt.panel, "Never for Zoom")
        ask(teamsCall)
        XCTAssertEqual(prompt.panel?.call, teamsCall, "other apps still ask")
    }

    func testNoPromptWhileRecording() {
        session.armImmediately = true
        model.perform(.start)
        wait("recording") { self.model.phase == .recording }
        ask(zoomCall)
        XCTAssertNil(prompt.panel)
        XCTAssertNil(prompt.unanswered)
    }

    func testNoPromptWhileSetupIsNeeded() {
        model.needsSetup = true
        ask(zoomCall)
        XCTAssertNil(prompt.panel)
    }

    func testNoPromptWhenAsksAreOff() {
        defaults.set(false, forKey: MeetingPromptPreference.askKey)
        ask(zoomCall)
        XCTAssertNil(prompt.panel)
        XCTAssertNil(prompt.unanswered)
    }

    func testASecondCallWhileAPanelShowsReplacesNothing() {
        ask(zoomCall)
        let first = prompt.panel
        ask(teamsCall)
        XCTAssertEqual(prompt.panel, first)
        // The second call is never asked about later, either.
        prompt.skip()
        prompt.tick()
        XCTAssertNil(prompt.panel)
    }

    func testAskPanelClosesWhenARecordingStartedAnotherWay() {
        ask(zoomCall)
        session.armImmediately = true
        model.perform(.start)
        wait("recording") { self.model.phase == .recording }
        prompt.tick()
        XCTAssertNil(prompt.panel)
        XCTAssertNil(prompt.unanswered, "answered by recording, not skipped")
    }

    func testTheEndOfAnUnansweredCallClearsIt() {
        ask(zoomCall)
        prompt.skip()
        prompt.handle([.ended(teamsCall)])
        XCTAssertEqual(prompt.unanswered, zoomCall, "another app's end changes nothing")
        prompt.handle([.ended(zoomCall)])
        XCTAssertNil(prompt.unanswered)
    }

    func testTheEndOfTheCallClosesItsAskPanel() {
        ask(zoomCall)
        prompt.handle([.ended(zoomCall)])
        XCTAssertNil(prompt.panel)
    }

    func testRecordUnansweredStartsWithThatSource() {
        ask(zoomCall)
        prompt.skip()
        prompt.recordUnanswered()
        XCTAssertNil(prompt.unanswered)
        XCTAssertEqual(model.recordingSourceAppID, "zoom")
        XCTAssertEqual(model.phase, .starting)
        wait("start called") { self.session.startCalls == 1 }
    }

    func testRecordUnansweredDoesNothingWithoutAnUnansweredCall() {
        prompt.recordUnanswered()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(session.startCalls, 0)
    }

    func testRecordedByHandAfterAPromptRecordingHasNoSource() {
        recordFromPanel(zoomCall)
        model.perform(.stop)
        wait("idle") { self.model.phase == .idle }
        model.perform(.start)
        XCTAssertNil(model.recordingSourceAppID)
        session.goLive()
    }

    // MARK: Call ended

    func testCallEndedOfTheRecordedAppAsksThenStopsAfterThirtySeconds() {
        recordFromPanel(zoomCall)
        prompt.handle([.ended(zoomCall)])
        XCTAssertEqual(prompt.panel, .callEnded(zoomCall, stopsAt: clock.addingTimeInterval(30)))
        advance(29)
        prompt.tick()
        XCTAssertNotNil(prompt.panel)
        XCTAssertEqual(model.phase, .recording)
        advance(1)
        prompt.tick()
        XCTAssertNil(prompt.panel)
        wait("idle after the automatic stop") { self.model.phase == .idle }
        XCTAssertEqual(session.stopCalls, 1)
        XCTAssertEqual(finished.count, 1)
    }

    func testAnotherAppsCallEndingDuringARecordingAsksNothing() {
        recordFromPanel(zoomCall)
        advance(5)
        prompt.tick()
        prompt.handle([.ended(teamsCall)])
        XCTAssertNil(prompt.panel)
        advance(60)
        prompt.tick()
        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(session.stopCalls, 0)
    }

    func testACallEndingDuringAHandStartedRecordingAsksNothing() {
        session.armImmediately = true
        model.perform(.start)
        wait("recording") { self.model.phase == .recording }
        prompt.handle([.ended(zoomCall)])
        XCTAssertNil(prompt.panel)
    }

    func testKeepRecordingClosesWithoutStopping() {
        recordFromPanel(zoomCall)
        prompt.handle([.ended(zoomCall)])
        prompt.keepRecording()
        XCTAssertNil(prompt.panel)
        advance(120)
        prompt.tick()
        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(session.stopCalls, 0)
    }

    func testStopNowStopsThroughThePerformPath() {
        recordFromPanel(zoomCall)
        prompt.handle([.ended(zoomCall)])
        prompt.stopNow()
        XCTAssertNil(prompt.panel)
        wait("idle") { self.model.phase == .idle }
        XCTAssertEqual(session.stopCalls, 1)
    }

    func testStoppingByHandClosesTheCallEndedPanelOnTheNextTick() {
        recordFromPanel(zoomCall)
        prompt.handle([.ended(zoomCall)])
        model.perform(.stop)
        wait("idle") { self.model.phase == .idle }
        prompt.tick()
        XCTAssertNil(prompt.panel)
        advance(60)
        prompt.tick()
        XCTAssertEqual(session.stopCalls, 1, "no second stop")
    }

    func testCallEndedIsSkippedWhenTheSettingIsOff() {
        defaults.set(false, forKey: MeetingPromptPreference.stopAtCallEndKey)
        recordFromPanel(zoomCall)
        advance(3)
        prompt.tick()
        prompt.handle([.ended(zoomCall)])
        XCTAssertNil(prompt.panel)
        XCTAssertEqual(model.phase, .recording)
    }

    func testTheCallEndedPanelIsNotReplacedByASecondEnd() {
        recordFromPanel(zoomCall)
        prompt.handle([.ended(zoomCall)])
        let first = prompt.panel
        advance(10)
        prompt.handle([.ended(zoomCall)])
        XCTAssertEqual(prompt.panel, first, "the 30 s countdown doesn't restart")
    }

    // MARK: Watched apps

    func testWatchedAppsFollowTheSettingsAndTheRecordingSource() {
        XCTAssertEqual(prompt.watchedApps, Set(MeetingApp.allIDs))
        defaults.set(false, forKey: MeetingPromptPreference.askKey)
        XCTAssertEqual(prompt.watchedApps, [])
        MeetingPromptPreference.setSkipped(["zoom"], defaults)
        session.armImmediately = true
        model.perform(.start, source: "zoom")
        wait("recording") { self.model.phase == .recording }
        XCTAssertEqual(prompt.watchedApps, ["zoom"], "the recorded app is watched so its end is seen")
        defaults.set(false, forKey: MeetingPromptPreference.stopAtCallEndKey)
        XCTAssertEqual(prompt.watchedApps, [])
    }

    // MARK: Through poll() with a fake mic and clock

    func testPollRunsACallFromMicToPanelAndBackToTheEnd() {
        mic.users = [MicUser(pid: 1, bundleID: "us.zoom.xos")]
        prompt.poll()
        advance(2)
        prompt.poll()
        XCTAssertNil(prompt.panel)
        advance(1)
        prompt.poll()
        XCTAssertEqual(prompt.panel?.call.appID, "zoom")
        prompt.skip()
        mic.users = []
        advance(5)
        prompt.poll()
        XCTAssertNotNil(prompt.unanswered)
        advance(10)
        prompt.poll()
        XCTAssertNil(prompt.unanswered, "the end of the call clears the ?")
    }

    // MARK: Browsers

    private func pollChrome(for seconds: TimeInterval) {
        mic.users = [MicUser(pid: 2, bundleID: "com.google.Chrome.helper")]
        prompt.poll()
        advance(seconds)
        prompt.poll()
        advance(1)
        prompt.poll()
    }

    func testAMeetingTabAsksWithTheSite() {
        tabs.answer = .meeting(host: "meet.google.com")
        pollChrome(for: 10)
        XCTAssertEqual(tabs.asked, ["chrome"])
        let panel = try! XCTUnwrap(prompt.panel)
        XCTAssertEqual(panel.call.site, "meet.google.com")
        XCTAssertEqual(MeetingPromptText.detail(panel), "Chrome has a tab on meet.google.com")
    }

    func testAnotherSiteOrNoMeetingTabAsksNothing() {
        tabs.answer = .notMeeting
        pollChrome(for: 10)
        XCTAssertEqual(tabs.asked, ["chrome"])
        XCTAssertNil(prompt.panel)
        XCTAssertNil(prompt.unanswered)
    }

    func testRefusedAutomationFallsBackToThePlainWording() {
        tabs.answer = .unknown
        pollChrome(for: 10)
        let panel = try! XCTUnwrap(prompt.panel)
        XCTAssertNil(panel.call.site)
        XCTAssertEqual(
            MeetingPromptText.detail(panel), "Chrome is using the microphone (its tabs couldn't be checked)")
    }

    // MARK: Words and script

    func testPanelWords() {
        let askPanel = MeetingPromptController.Panel.ask(zoomCall, closesAt: clock.addingTimeInterval(12))
        XCTAssertEqual(MeetingPromptText.header(askPanel), "MEETING STARTED")
        XCTAssertEqual(MeetingPromptText.question(askPanel), "Transcribe this meeting?")
        XCTAssertEqual(MeetingPromptText.detail(askPanel), "Zoom is using the microphone")
        XCTAssertEqual(MeetingPromptText.countdown(askPanel, now: clock), "closes in 12 s")
        XCTAssertEqual(MeetingPromptText.countdown(askPanel, now: clock.addingTimeInterval(99)), "closes in 0 s")
        let ended = MeetingPromptController.Panel.callEnded(zoomCall, stopsAt: clock.addingTimeInterval(30))
        XCTAssertEqual(MeetingPromptText.question(ended), "Call ended. Stop?")
        XCTAssertEqual(MeetingPromptText.countdown(ended, now: clock), "stops in 30 s")
        let rec = MeetingPromptController.Panel.recording(zoomCall, closesAt: clock)
        XCTAssertNil(MeetingPromptText.countdown(rec, now: clock))
        XCTAssertTrue(MeetingPromptText.reminder.contains("Audio stays on this Mac"))
    }

    func testTheTabScriptNamesOnlyChromeAndSafariAndOnlyReadsURLs() {
        let chrome = try! XCTUnwrap(AppleScriptBrowserTabs.script(for: "chrome"))
        let safari = try! XCTUnwrap(AppleScriptBrowserTabs.script(for: "safari"))
        for (script, bundle) in [(chrome, "com.google.Chrome"), (safari, "com.apple.Safari")] {
            XCTAssertTrue(script.contains("application id \"\(bundle)\""))
            XCTAssertTrue(script.contains("is running"), "a quit browser must not be launched")
            XCTAssertTrue(script.contains("get URL of every tab of every window"))
            XCTAssertFalse(script.contains("execute"))
            XCTAssertFalse(script.contains("do shell script"))
        }
        XCTAssertFalse(chrome.contains("com.apple.Safari"))
        XCTAssertFalse(safari.contains("com.google.Chrome"))
        XCTAssertNil(AppleScriptBrowserTabs.script(for: "zoom"))
        XCTAssertNil(AppleScriptBrowserTabs.script(for: ""))
    }

    // MARK: M9 review findings

    func testM9ReviewFinding1ARejoinedCallCancelsCallEnded() {
        session.armImmediately = true
        model.perform(.start, source: "zoom")
        wait("recording") { self.model.phase == .recording }
        prompt.handle([.ended(zoomCall)])
        XCTAssertEqual(prompt.panel, .callEnded(zoomCall, stopsAt: clock.addingTimeInterval(30)))
        advance(10)
        prompt.handle([.started(zoomCall)])
        XCTAssertNil(prompt.panel, "the call came back: the question closes")
        advance(60)
        prompt.tick()
        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(session.stopCalls, 0)
    }

    func testM9ReviewFinding2QuestionMarkClearsWhenAsksAreTurnedOff() {
        mic.users = [MicUser(pid: 1, bundleID: "us.zoom.xos")]
        prompt.poll()
        advance(3)
        prompt.poll()
        prompt.skip()
        XCTAssertNotNil(prompt.unanswered)
        defaults.set(false, forKey: MeetingPromptPreference.askKey)
        advance(15)
        prompt.poll()
        XCTAssertNil(prompt.unanswered, "nothing is watched, so the ? goes")
        XCTAssertEqual(session.startCalls, 0)
        // Asks back on: holding zoom again prompts.
        defaults.set(true, forKey: MeetingPromptPreference.askKey)
        advance(100)
        prompt.poll()
        advance(3)
        prompt.poll()
        XCTAssertEqual(prompt.panel?.call.appID, "zoom")
    }

    /// A is recorded and its call ends; A is stopped and B (a new session object) starts.
    private func callEndedForAThenBRecording() -> FakeSession {
        recordFromPanel(zoomCall)
        prompt.handle([.ended(zoomCall)])
        XCTAssertNotNil(prompt.panel)
        model.perform(.stop)
        wait("idle") { self.model.phase == .idle }
        let b = FakeSession()
        b.armImmediately = true
        model.makeSession = { b }
        model.perform(.start)
        wait("recording B") { self.model.phase == .recording }
        return b
    }

    func testM9ReviewFinding3TickPastTheDeadlineNeverStopsANewerRecording() {
        let b = callEndedForAThenBRecording()
        advance(31)
        prompt.tick()
        XCTAssertNil(prompt.panel)
        settle(0.2)
        XCTAssertEqual(model.phase, .recording, "B keeps recording")
        XCTAssertEqual(b.stopCalls, 0)
    }

    func testM9ReviewFinding3StopNowNeverStopsANewerRecording() {
        let b = callEndedForAThenBRecording()
        prompt.stopNow()
        XCTAssertNil(prompt.panel)
        settle(0.2)
        XCTAssertEqual(model.phase, .recording, "B keeps recording")
        XCTAssertEqual(b.stopCalls, 0)
    }

    func testM9ReviewFinding4OneTabCheckAtATime() {
        tabs.holds = true
        prompt.handle([.checkTabs(appID: "chrome")])
        prompt.handle([.checkTabs(appID: "chrome")])
        XCTAssertEqual(tabs.asked, ["chrome"], "the second is not queued while the first waits")
        XCTAssertEqual(prompt.tabChecksInFlight, ["chrome"])
        tabs.release()
        XCTAssertTrue(prompt.tabChecksInFlight.isEmpty)
        prompt.handle([.checkTabs(appID: "chrome")])
        XCTAssertEqual(tabs.asked, ["chrome", "chrome"], "after the answer a later check goes through")
    }

    func testM9ReviewFinding9RecordWhenStartIsNoLongerPossibleKeepsTheCall() {
        ask(zoomCall)
        model.needsSetup = true
        prompt.record()
        XCTAssertNil(prompt.panel)
        XCTAssertEqual(prompt.unanswered, zoomCall)
        XCTAssertEqual(session.startCalls, 0)
    }

    func testPreferenceDefaults() {
        XCTAssertTrue(defaults.bool(forKey: MeetingPromptPreference.askKey))
        XCTAssertTrue(defaults.bool(forKey: MeetingPromptPreference.stopAtCallEndKey))
        XCTAssertEqual(prompt.timeout, 20)
        XCTAssertEqual(MeetingPromptPreference.skippedApps(defaults), [])
        MeetingPromptPreference.setSkipped(["zoom", "teams"], defaults)
        XCTAssertEqual(MeetingPromptPreference.skippedApps(defaults), ["zoom", "teams"])
    }
}

/// The menu bar side of a skipped call.
final class MeetingPromptMenuBarTests: MeetingPromptTestCase {
    func testQuestionMarkGlyphAndRecordThisCallWhileIdleWithAnUnansweredCall() {
        XCTAssertFalse(MenuBarItem.items(for: model).contains { $0.action == .recordCall })
        ask(zoomCall)
        prompt.skip()
        let items = MenuBarItem.items(for: model)
        XCTAssertEqual(items.first?.title, "Record This Call")
        XCTAssertEqual(items.first?.action, .recordCall)
        XCTAssertEqual(items.first?.enabled, true)
        XCTAssertEqual(MenuBarGlyph(model.activity, unansweredCall: prompt.unanswered != nil), .asking)
        XCTAssertEqual(
            MenuBarText.status(model.activity, unansweredCall: prompt.unanswered?.appName), "? Zoom call, not recording"
        )
        // The item does what the menu runs.
        prompt.recordUnanswered()
        XCTAssertEqual(model.recordingSourceAppID, "zoom")
        XCTAssertFalse(MenuBarItem.items(for: model).contains { $0.action == .recordCall })
    }

    func testRecordingWinsOverTheQuestionMark() {
        ask(zoomCall)
        prompt.skip()
        session.armImmediately = true
        model.perform(.start)
        wait("recording") { self.model.phase == .recording }
        XCTAssertEqual(MenuBarGlyph(model.activity, unansweredCall: true), .recording)
        XCTAssertFalse(MenuBarItem.items(for: model).contains { $0.action == .recordCall })
        XCTAssertEqual(MenuBarText.status(.recording(elapsed: 5), unansweredCall: "Zoom"), "● Recording 00:05")
    }
}
