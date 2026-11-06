import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Each test is named after a bug from the code review (M3 spec).
final class CaptureBugTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        return path
    }

    // MARK: Chunk offset used the last segment's end

    func testTrailingSilenceInAChunkDoesNotShiftLaterTimestamps() {
        // The first chunk is 30 s long, but its speech ends at 10 s.
        let first = Transcriber.Segment(start: 8, end: 10, text: "one")
        let second = Transcriber.Segment(start: 1, end: 2, text: "two")
        let stitched = Transcriber.stitch([
            .init(duration: 30, text: "one", segments: [first]),
            .init(duration: 30, text: "two", segments: [second]),
        ])
        XCTAssertEqual(stitched.segments.map(\.start), [8, 31])
        XCTAssertEqual(stitched.segments.map(\.end), [10, 32])
        XCTAssertEqual(stitched.text, "one two")
    }

    func testASilentChunkStillAdvancesTime() {
        let later = Transcriber.Segment(start: 1, end: 2, text: "later")
        let stitched = Transcriber.stitch([
            .init(duration: 30, text: "", segments: []),
            .init(duration: 30, text: "later", segments: [later]),
        ])
        XCTAssertEqual(stitched.segments.map(\.start), [31])
    }

    func testAnUnreadableDurationFallsBackToTheLastSegment() {
        let first = Transcriber.Segment(start: 0, end: 10, text: "one")
        let second = Transcriber.Segment(start: 1, end: 2, text: "two")
        let stitched = Transcriber.stitch([
            .init(duration: nil, text: "one", segments: [first]),
            .init(duration: 30, text: "two", segments: [second]),
        ])
        XCTAssertEqual(stitched.segments.map(\.start), [0, 11])
    }

    // MARK: Shell transcribe ignored _partN files

    func testAllPartsAreFoundInOrder() throws {
        let first = try touch("meeting.wav")
        let tenth = try touch("meeting_part10.wav")
        let second = try touch("meeting_part2.wav")
        _ = try touch("meeting_partly.wav")
        _ = try touch("other_part2.wav")
        XCTAssertEqual(RecordingFiles.allParts(of: first), [first, second, tenth])
        XCTAssertEqual(RecordingFiles.allParts(of: second), [first, second, tenth])
    }

    func testAFileWithNoPartsIsJustItself() throws {
        let only = try touch("solo.wav")
        XCTAssertEqual(RecordingFiles.allParts(of: only), [only])
    }

    // MARK: Speex sample rate left at 8 kHz

    func testEchoCancellerRunsAt48kHz() {
        XCTAssertEqual(EchoCanceller().configuredSampleRate, 48_000)
    }

    // MARK: Enter doesn't stop a flag-mode recording

    func testEnterStopsAndSpaceEnterPauses() {
        XCTAssertEqual(RecordingKeys.action(for: Data([0x0A])), .stop)
        XCTAssertEqual(RecordingKeys.action(for: Data([0x20, 0x0A])), .pauseToggle)
        XCTAssertEqual(RecordingKeys.action(for: Data([0x71, 0x0A])), .stop)
    }

    // MARK: Duration timer not cancelled; double stop can resume twice

    func testStoppingTwiceThenFiringTheTimerGivesOneStop() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.arm())
        var stops = 0
        func stop() { if stopper.claimStop() { stops += 1 } }

        stopper.startTimer(after: 0.05) { stop() }
        stop()
        stop()

        let waited = expectation(description: "the timer's moment has passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(stops, 1)
    }

    func testTheTimerStopsARecordingNobodyStopped() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.arm())
        let fired = expectation(description: "timer fired")
        stopper.startTimer(after: 0.01) {
            XCTAssertTrue(stopper.claimStop())
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)
    }

    // MARK: Chrome or Safari can capture silently when the call is elsewhere

    func testBrowserTargetWarnsAndOffersAllAudio() throws {
        let chrome = try XCTUnwrap(MeetingApp.catalog.first { $0.id == "chrome" })
        let warning = try XCTUnwrap(AudioCapture.targetWarning(for: chrome))
        XCTAssertTrue(warning.contains(chrome.label))
        XCTAssertTrue(warning.contains("--all-audio"))
        XCTAssertTrue(warning.contains("All system audio"))
        XCTAssertNotNil(AudioCapture.targetWarning(for: MeetingApp.catalog.first { $0.id == "safari" }!))
    }

    func testAConferencingAppDoesNotWarn() throws {
        let zoom = try XCTUnwrap(MeetingApp.catalog.first { $0.id == "zoom" })
        XCTAssertNil(AudioCapture.targetWarning(for: zoom))
    }

    // MARK: Progress and "Captured" counted paused time

    func testPausedAudioIsNotCounted() throws {
        let writer = try TrackWriter(outputURL: dir.appendingPathComponent("p.wav"))
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800

        writer.pushSystem(buffer)
        writer.togglePause()
        writer.pushSystem(buffer)
        writer.togglePause()
        writer.pushSystem(buffer)
        XCTAssertEqual(writer.framesWritten, 9600)
    }

    // MARK: Start-up box said stereo f32; "Ctrl+C to stop" in shell mode

    func testStartUpTextMatchesTheRealFormatAndKey() {
        XCTAssertFalse(AudioCapture.formatDescription.contains("f32"))
        XCTAssertTrue(AudioCapture.formatDescription.contains("int16"))
        XCTAssertFalse(AudioCapture.recordingHint.contains("Ctrl+C"))
        XCTAssertTrue(AudioCapture.recordingHint.contains("Enter to stop"))
    }
}
