import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Finding (user report: mic silent after a device change mid-recording): macOS stops the engine
/// on AVAudioEngineConfigurationChange and the mic stayed silent for the rest of the call.
/// `restartAfterDeviceChange()` must bring it back. These tests use the real input device and skip
/// where there is none or no Microphone permission. The notification itself can't be posted from
/// here: it is delivered with `object: engine`, and the engine is private to MicCapture, so the
/// method is called directly (production runs it on the private `control` queue).
final class MicCaptureRestartTests: XCTestCase {

    private func makeStartedMic(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> MicCapture {
        let mic: MicCapture
        do { mic = try MicCapture() } catch { throw XCTSkip("No input device here (CI or no mic): \(error)") }
        do { try mic.start() } catch {
            throw XCTSkip("mic.start() failed, likely no Microphone permission for the test runner: \(error)")
        }
        return mic
    }

    /// Thread-safe collector, since the tap calls back on an audio thread.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames = 0
        private var _lines: [String] = []
        var frames: Int {
            lock.lock()
            defer { lock.unlock() }
            return _frames
        }
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _lines
        }
        func add(frames n: Int) {
            lock.lock()
            _frames += n
            lock.unlock()
        }
        func add(line: String) {
            lock.lock()
            _lines.append(line)
            lock.unlock()
        }
    }

    private func wire(_ mic: MicCapture) -> Box {
        let box = Box()
        mic.onSamples = { _, n in box.add(frames: n) }
        mic.onDeviceChange = { box.add(line: $0) }
        return box
    }

    /// Polls up to `seconds` for `cond`.
    private func wait(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return cond()
    }

    func testUserReportMicSilentAfterDeviceChangeKeepsRecordingAfterRestart() throws {
        let mic = try makeStartedMic()
        defer { mic.stop() }
        let box = wire(mic)

        XCTAssertTrue(
            wait(3) { box.frames > 0 }, "samples arrive before the change (else no live mic: not a product failure)")
        mic.restartAfterDeviceChange()

        XCTAssertEqual(mic.restarts, 1)
        XCTAssertEqual(box.lines.count, 1)
        XCTAssertTrue(
            box.lines.first?.contains("now ") == true && box.lines.first?.contains(" Hz") == true,
            "line was: \(box.lines)")
        let before = box.frames
        XCTAssertTrue(wait(3) { box.frames > before }, "samples must keep reaching onSamples after the restart")
    }

    func testRestartTwiceInARowStillRecords() throws {
        let mic = try makeStartedMic()
        defer { mic.stop() }
        let box = wire(mic)
        mic.restartAfterDeviceChange()
        mic.restartAfterDeviceChange()
        XCTAssertEqual(mic.restarts, 2)
        let before = box.frames
        XCTAssertTrue(wait(3) { box.frames > before })
    }

    func testRestartAfterStopDoesNothing() throws {
        let mic = try makeStartedMic()
        let box = wire(mic)
        mic.stop()
        mic.restartAfterDeviceChange()
        XCTAssertEqual(mic.restarts, 0)
        XCTAssertTrue(box.lines.isEmpty, "no line after stop: \(box.lines)")
        let after = box.frames
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(box.frames, after, "a stopped mic must not deliver samples again")
    }

    func testRestartBeforeStartDoesNothing() throws {
        let mic: MicCapture
        do { mic = try MicCapture() } catch { throw XCTSkip("No input device here (CI or no mic): \(error)") }
        let box = wire(mic)
        mic.restartAfterDeviceChange()
        XCTAssertEqual(mic.restarts, 0)
        XCTAssertTrue(box.lines.isEmpty)
    }

    func testStopTwiceAndRestartThenStopDoNotCrash() throws {
        let mic = try makeStartedMic()
        _ = wire(mic)
        mic.restartAfterDeviceChange()
        mic.stop()
        mic.stop()
        mic.restartAfterDeviceChange()
        XCTAssertEqual(mic.restarts, 1)
    }

    func testStopRightAfterRestartFromAnotherQueueDoesNotDeadlock() throws {
        let mic = try makeStartedMic()
        _ = wire(mic)
        let done = expectation(description: "restart and stop finish")
        done.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            mic.restartAfterDeviceChange()
            done.fulfill()
        }
        DispatchQueue.global().async {
            mic.stop()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        mic.stop()
    }
}
