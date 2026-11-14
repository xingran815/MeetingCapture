import AppKit
import XCTest

@testable import MeetingCaptureCore
@testable import MeetingCaptureDesktop

/// A session with no capture. Its stop goes through a real `RecordingStopper`, like
/// `AudioCapture`'s, so an early stop is held until `goLive()`.
@MainActor
final class FakeSession: RecordingSession {
    let base = URL(fileURLWithPath: "/tmp/mc-fake/20261114_090000")
    var isLive = false
    var elapsedSeconds = 65.0
    var isPaused = false
    var levels: (mic: Float, system: Float) = (0, 0)
    var sourceLabel = "Fake call"
    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    private(set) var stopCalls = 0
    private(set) var endedCount = 0
    private let stopper = RecordingStopper()
    private var continuation: CheckedContinuation<[URL], Error>?
    /// When true, stop() ignores the stopper (a session with no hold), for the plain command tests.
    var armImmediately = false

    func start() async throws -> [URL] {
        startCalls += 1
        if armImmediately { goLive() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func goLive() {
        isLive = true
        if stopper.arm() { end() }
    }

    func togglePause() -> Bool {
        pauseCalls += 1
        isPaused.toggle()
        return isPaused
    }

    func stop() {
        stopCalls += 1
        if stopper.claimStop() { end() }
    }

    private func end() {
        endedCount += 1
        continuation?.resume(returning: [base.appendingPathExtension("wav")])
        continuation = nil
    }
}

@MainActor
class AppModelTestCase: XCTestCase {
    private var temp: URL!
    private var saved: [String: String?] = [:]
    var model: AppModel!
    var session: FakeSession!
    var finished: [(parts: [URL], base: URL)] = []

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-desktop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let keys = [
            "MEETINGCAPTURE_E2E", "MEETINGCAPTURE_HOME", "MEETINGCAPTURE_DEMO", "MEETINGCAPTURE_SNAPSHOT",
            "MEETINGCAPTURE_MENUBAR_SNAPSHOT", "MEETINGCAPTURE_THEME",
        ]
        for k in keys { saved[k] = getenv(k).map { String(cString: $0) } }
        setenv("MEETINGCAPTURE_E2E", "1", 1)
        setenv("MEETINGCAPTURE_HOME", temp.path, 1)
        for k in ["MEETINGCAPTURE_DEMO", "MEETINGCAPTURE_SNAPSHOT", "MEETINGCAPTURE_MENUBAR_SNAPSHOT"] {
            unsetenv(k)
        }
        model = AppModel()
        model.needsSetup = false
        session = FakeSession()
        model.makeSession = { [unowned self] in self.session }
        model.afterRecording = { [unowned self] parts, base in self.finished.append((parts, base)) }
    }

    override func tearDown() async throws {
        model.stopRecording()
        for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        try? FileManager.default.removeItem(at: temp)
        model = nil
    }

    /// Runs the main run loop until the condition holds (the model's meter timer and Task need it).
    func wait(_ what: String, timeout: TimeInterval = 3, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func settle(_ seconds: TimeInterval = 0.3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func menuAction(_ command: RecordingCommand) -> MenuBarItem? {
        MenuBarItem.items(for: model).first { $0.action == .command(command) }
    }

    func demoJob(running: Int) -> AppModel.Job {
        let stages: [ProcessingStage] = [.removingEcho, .transcribing, .labellingSpeakers, .writingReport]
        var steps = stages.map { AppModel.StepState(stage: $0) }
        for i in 0..<running { steps[i].status = .done }
        steps[running].status = .running
        return AppModel.Job(
            kind: .newRecording, base: URL(fileURLWithPath: "/tmp/mc-fake/job"), title: "Invented", steps: steps)
    }
}

final class AppModelCommandTests: AppModelTestCase {
    func testCanPerformWhenIdle() {
        XCTAssertTrue(model.canPerform(.start))
        XCTAssertFalse(model.canPerform(.pauseResume))
        XCTAssertFalse(model.canPerform(.stop))
        model.needsSetup = true
        XCTAssertFalse(model.canPerform(.start), "setup first")
    }

    func testCommandsDriveTheSession() {
        session.armImmediately = true
        let start = menuAction(.start)
        XCTAssertEqual(start?.action, .command(.start))
        XCTAssertEqual(start?.enabled, true)
        model.perform(.start)
        XCTAssertEqual(model.phase, .starting)
        XCTAssertFalse(model.canPerform(.start))
        XCTAssertFalse(model.canPerform(.pauseResume), "no pause before capture is live")
        XCTAssertTrue(model.canPerform(.stop))
        wait("recording phase") { self.model.phase == .recording }
        XCTAssertEqual(session.startCalls, 1)
        XCTAssertTrue(model.canPerform(.pauseResume))

        let pause = menuAction(.pauseResume)
        XCTAssertEqual(pause?.title, "Pause")
        model.perform(.pauseResume)
        XCTAssertEqual(session.pauseCalls, 1)
        XCTAssertTrue(model.paused)
        XCTAssertEqual(menuAction(.pauseResume)?.title, "Resume")
        if case .paused = model.activity {} else { XCTFail("activity \(model.activity)") }

        model.perform(.pauseResume)
        XCTAssertFalse(model.paused)

        XCTAssertEqual(menuAction(.stop)?.enabled, true)
        model.perform(.stop)
        wait("idle after stop") { self.model.phase == .idle }
        XCTAssertEqual(session.stopCalls, 1)
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(menuAction(.start)?.enabled, true)
    }

    func testActivityDerivation() {
        XCTAssertEqual(model.activity, .idle)
        model.showDemoJob(demoJob(running: 1))
        XCTAssertEqual(model.activity, .processing(step: 2, of: 4, name: ProcessingStage.transcribing.title))
        var done = demoJob(running: 1)
        done.finished = true
        model.showDemoJob(done)
        XCTAssertEqual(model.activity, .idle)
    }

    func testRecordingWinsOverRunningJob() {
        session.armImmediately = true
        model.showDemoJob(demoJob(running: 0))
        if case .processing = model.activity {} else { XCTFail("expected processing") }
        model.perform(.start)
        XCTAssertEqual(model.activity, .starting)
        wait("recording") { self.model.phase == .recording }
        if case .recording = model.activity {} else { XCTFail("recording must win, got \(model.activity)") }
        model.perform(.stop)
        wait("idle") { self.model.phase == .idle }
        if case .processing = model.activity {} else { XCTFail("job goes on underneath") }
    }

    func testSecondStartIsIgnored() {
        session.armImmediately = true
        model.perform(.start)
        model.perform(.start)
        wait("recording") { self.model.phase == .recording }
        XCTAssertEqual(session.startCalls, 1)
    }

    func testQuitWarningWhileRecording() {
        XCTAssertNil(model.quitWarning)
        session.armImmediately = true
        model.perform(.start)
        XCTAssertNotNil(model.quitWarning)
        wait("recording") { self.model.phase == .recording }
        XCTAssertNotNil(model.quitWarning)
        model.showDemoJob(demoJob(running: 0))
        XCTAssertNotNil(model.quitWarning)
    }

    func testLastReportRowFollowsLibrary() {
        XCTAssertNil(model.lastReport)
        XCTAssertFalse(MenuBarItem.items(for: model).contains { $0.action == .openLastReport })
    }
}

/// The spec's Done-when: an early Stop from the menu waits for capture to be live.
final class MenuStopHeldUntilLiveTests: AppModelTestCase {
    func testEarlyStopFromMenuIsHeldUntilCaptureIsLive() {
        model.perform(menuAction(.start).map { _ in .start }!)
        XCTAssertEqual(model.phase, .starting)
        wait("start() to be called") { self.session.startCalls == 1 }

        // The Stop item is offered while starting and reaches the session.
        let stop = menuAction(.stop)
        XCTAssertEqual(stop?.enabled, true)
        model.perform(.stop)
        XCTAssertEqual(session.stopCalls, 1)
        settle(0.4)  // past several meter ticks
        XCTAssertEqual(session.endedCount, 0, "stop must wait for the capture to be live")
        XCTAssertTrue(finished.isEmpty)
        XCTAssertEqual(model.phase, .starting)

        // A second early stop must not end it either.
        model.perform(.stop)
        settle(0.2)
        XCTAssertEqual(session.endedCount, 0)

        session.goLive()
        wait("recording to end") { self.model.phase == .idle }
        XCTAssertEqual(session.endedCount, 1)
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.base, session.base)

        // Stops after the end do nothing more.
        model.perform(.stop)
        settle(0.2)
        XCTAssertEqual(session.endedCount, 1)
        XCTAssertEqual(finished.count, 1)
    }

    func testPhaseBecomesRecordingOnlyOnceLive() {
        model.perform(.start)
        wait("start() to be called") { self.session.startCalls == 1 }
        settle(0.35)
        XCTAssertEqual(model.phase, .starting, "not live yet")
        XCTAssertFalse(model.canPerform(.pauseResume))
        session.goLive()
        wait("recording phase") { self.model.phase == .recording }
        XCTAssertEqual(model.elapsed, 65, accuracy: 0.01)
        XCTAssertEqual(model.sourceLabel, "Fake call")
        model.perform(.stop)
        wait("idle") { self.model.phase == .idle }
        XCTAssertEqual(session.endedCount, 1)
    }

    func testStopAfterLiveEndsOnceEvenWhenPressedTwice() {
        model.perform(.start)
        wait("start() to be called") { self.session.startCalls == 1 }
        session.goLive()
        wait("recording phase") { self.model.phase == .recording }
        model.perform(.stop)
        model.perform(.stop)
        wait("idle") { self.model.phase == .idle }
        XCTAssertEqual(session.endedCount, 1)
        XCTAssertEqual(finished.count, 1)
    }
}

final class WindowAndDemoTests: XCTestCase {
    @MainActor
    func testClosingTheLastWindowDoesNotQuit() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @MainActor
    func testDemoStateDoesNothingWithoutE2E() {
        let keys = ["MEETINGCAPTURE_E2E", "MEETINGCAPTURE_DEMO"]
        let saved = keys.map { k in getenv(k).map { String(cString: $0) } }
        defer { for (k, v) in zip(keys, saved) { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        unsetenv("MEETINGCAPTURE_E2E")
        setenv("MEETINGCAPTURE_DEMO", "recording", 1)
        XCTAssertNil(DemoState.requested)
        setenv("MEETINGCAPTURE_E2E", "1", 1)
        XCTAssertEqual(DemoState.requested, "recording")
        unsetenv("MEETINGCAPTURE_DEMO")
        XCTAssertNil(DemoState.requested)
    }
}
