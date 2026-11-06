import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Rotation is proved with a 2-second chunk, never by waiting 30 minutes.
final class TrackWriterTests: XCTestCase {

    private var dir: URL!
    private let rate = Int(TrackWriter.sampleRate)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// One second of interleaved stereo float32, the shape SCStream delivers.
    private func oneSecond(value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.sampleRate,
                channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = AVAudioFrameCount(rate)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<rate * 2 { samples[i] = value }
        return buffer
    }

    /// Writes `seconds`, lets the writer deallocate to finalize headers, returns the frame count of each file.
    private func write(
        seconds: Int, target: Double = 0, chunkSeconds: Int = 2,
        during: (TrackWriter, Int) -> Void = { _, _ in }
    ) throws -> [(name: String, frames: Int)] {
        var files: [URL] = []
        try autoreleasepool {
            let writer = try TrackWriter(
                outputURL: dir.appendingPathComponent("meeting.wav"),
                targetDurationSeconds: target,
                chunkFrameLimit: chunkSeconds * rate)
            for s in 0..<seconds {
                during(writer, s)
                writer.pushSystem(try oneSecond())
            }
            files = writer.finish()
        }
        return try files.map { url in
            (url.lastPathComponent, Int(try AVAudioFile(forReading: url).length))
        }
    }

    func testRotatesAtTheInjectedChunkLength() throws {
        let files = try write(seconds: 5)
        XCTAssertEqual(files.map(\.name), ["meeting.wav", "meeting_part2.wav", "meeting_part3.wav"])
        XCTAssertEqual(files.map(\.frames), [2 * rate, 2 * rate, rate])
    }

    func testNoSpuriousChunkWhenTargetEqualsAChunkBoundary() throws {
        let files = try write(seconds: 4, target: 4)
        XCTAssertEqual(files.map(\.name), ["meeting.wav", "meeting_part2.wav"])
    }

    func testPausedAudioIsDroppedNotSpliced() throws {
        let files = try write(seconds: 3, chunkSeconds: 100) { writer, second in
            if second == 1 || second == 2 { writer.togglePause() }
        }
        XCTAssertEqual(files.map(\.frames), [2 * rate], "the paused second must not reach the file")
    }

    // MARK: Rotation

    /// A ramp across the whole recording: any lost or repeated audio breaks the steps.
    private func assertRamp(
        _ samples: [Float], total: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(samples.count, total, file: file, line: line)
        let step = 1 / Float(total)
        let biggestJump = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(biggestJump, step + 2 / 32_767, "a jump means audio went missing", file: file, line: line)
        XCTAssertEqual(samples.first ?? -1, 0, accuracy: 0.001, file: file, line: line)
    }

    func testRotationLosesAndRepeatsNoAudioOnEitherTrack() throws {
        let buffer = rate * 7 / 10  // doesn't fit a chunk evenly
        let total = buffer * 4
        var files: [URL] = []
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: dir.appendingPathComponent("m.wav"), chunkFrameLimit: rate)
            for n in 0..<4 {
                let ramp: (Int) -> Float = { Float(n * buffer + $0) / Float(total) }
                TestAudio.pushMic(writer, frames: buffer, ramp)
                writer.pushSystem(try TestAudio.stereo(frames: buffer, ramp))
            }
            files = writer.finish()
        }
        XCTAssertGreaterThan(files.count, 1, "this has to cross a rotation to prove anything")
        let tracks = try files.map(TestAudio.tracks(of:))
        assertRamp(tracks.flatMap(\.mic), total: total)
        assertRamp(tracks.flatMap(\.system), total: total)
    }

    func testABufferBiggerThanAChunkStaysWhole() throws {
        var files: [URL] = []
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: dir.appendingPathComponent("m.wav"), chunkFrameLimit: rate / 2)
            writer.pushSystem(try TestAudio.stereo(frames: rate * 2) { _ in 0.1 })
            files = writer.finish()
        }
        XCTAssertEqual(try AVAudioFile(forReading: files[0]).length, AVAudioFramePosition(rate * 2))
    }

    /// A folder sits where the next part would go, as a full or read-only disk would fail.
    func testAPartThatCantBeCreatedKeepsAudioInTheCurrentFile() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("meeting_part2.wav"), withIntermediateDirectories: false)
        let files = try write(seconds: 4)
        XCTAssertEqual(files.map(\.name), ["meeting.wav"])
        XCTAssertEqual(files.map(\.frames), [4 * rate], "nothing may be dropped while rotation fails")
    }

    func testAudioPastTheTargetLengthIsStillKept() throws {
        let files = try write(seconds: 3, target: 1, chunkSeconds: 1)
        XCTAssertEqual(files.reduce(0) { $0 + $1.frames }, 3 * rate)
    }

    // MARK: Mic track

    private func writeOne(_ during: (TrackWriter) throws -> Void) throws -> (mic: [Float], system: [Float]) {
        let url = dir.appendingPathComponent("one.wav")
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            try during(writer)
        }
        return try TestAudio.tracks(of: url)
    }

    func testTheMicGoesInChannelOneAndSystemInChannelTwo() throws {
        let tracks = try writeOne { writer in
            TestAudio.pushMic(writer, frames: rate / 10) { _ in 0.25 }
            writer.pushSystem(try TestAudio.stereo(frames: rate / 10) { _ in -0.5 })
        }
        XCTAssertEqual(try XCTUnwrap(tracks.mic.first), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tracks.system.first), -0.5, accuracy: 0.001)
    }

    func testAMicFIFOOverItsCapKeepsTheNewestAudio() throws {
        let tracks = try writeOne { writer in
            // Two seconds of mic, nothing draining it: old audio is 0.1 and new audio 0.4.
            TestAudio.pushMic(writer, frames: rate) { _ in 0.1 }
            TestAudio.pushMic(writer, frames: rate) { _ in 0.4 }
            writer.pushSystem(try TestAudio.stereo(frames: rate) { _ in 0 })
        }
        XCTAssertEqual(tracks.mic.first ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(tracks.mic.last ?? 0, 0.4, accuracy: 0.001)
    }

    func testAMicThatFallsBehindIsSilenceNotStaleAudio() throws {
        let tracks = try writeOne { writer in
            TestAudio.pushMic(writer, frames: rate / 2) { _ in 0.25 }
            writer.pushSystem(try TestAudio.stereo(frames: rate) { _ in 0.1 })
        }
        XCTAssertEqual(tracks.mic.count, rate)
        XCTAssertEqual(tracks.mic[rate / 2 - 1], 0.25, accuracy: 0.001)
        XCTAssertEqual(tracks.mic[rate / 2], 0, "the rest of the mic track is silence")
        XCTAssertEqual(tracks.system[rate - 1], 0.1, accuracy: 0.001, "system audio keeps the clock")
    }

    func testMicHeardBeforeAPauseIsNotSplicedInAfterIt() throws {
        let tracks = try writeOne { writer in
            TestAudio.pushMic(writer, frames: rate / 2) { _ in 0.5 }
            writer.togglePause()
            TestAudio.pushMic(writer, frames: rate / 2) { _ in 0.5 }
            writer.togglePause()
            writer.pushSystem(try TestAudio.stereo(frames: rate / 10) { _ in 0.1 })
        }
        XCTAssertEqual(tracks.mic.max(), 0, "nothing from before or during the pause may appear")
    }

    func testTogglePauseReportsTheNewState() throws {
        let writer = try TrackWriter(outputURL: dir.appendingPathComponent("p.wav"))
        XCTAssertTrue(writer.togglePause())
        XCTAssertFalse(writer.togglePause())
    }

    // MARK: Samples that could break the file

    func testLoudAudioClipsInsteadOfWrappingAround() throws {
        let tracks = try writeOne { writer in
            TestAudio.pushMic(writer, frames: 10) { _ in -5 }
            writer.pushSystem(try TestAudio.stereo(frames: 10) { _ in 5 })
        }
        XCTAssertEqual(tracks.system[0], 1, accuracy: 0.001, "wrapping would make this negative")
        XCTAssertEqual(tracks.mic[0], -1, accuracy: 0.001)
    }

    /// `Int16(_:)` traps on NaN, so one bad sample would end the recording.
    func testNonFiniteSamplesDontCrashTheRecording() throws {
        let tracks = try writeOne { writer in
            TestAudio.pushMic(writer, frames: 3) { [Float.nan, .infinity, -.infinity][$0] }
            writer.pushSystem(try TestAudio.stereo(frames: 3) { [Float.nan, .infinity, -.infinity][$0] })
        }
        XCTAssertEqual(tracks.system.count, 3)
    }

    func testPushingFromTwoQueuesWhilePausingLosesNoAccounting() throws {
        let writer = try TrackWriter(outputURL: dir.appendingPathComponent("c.wav"), chunkFrameLimit: rate / 10)
        let buffer = try TestAudio.stereo(frames: 480) { _ in 0.1 }
        let group = DispatchGroup()
        for queue in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<200 {
                    switch queue {
                    case 0: writer.pushSystem(buffer)
                    case 1: TestAudio.pushMic(writer, frames: 480) { _ in 0.1 }
                    default:
                        writer.togglePause()
                        writer.togglePause()
                    }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        // Pauses may swallow some pushes, but what's counted is what reached the files.
        XCTAssertEqual(writer.framesWritten % 480, 0, "a push is written whole or not at all")
        XCTAssertLessThanOrEqual(writer.framesWritten, 200 * 480)
    }
}
