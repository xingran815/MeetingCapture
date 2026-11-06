import AVFoundation
import XCTest
@testable import MeetingCaptureCore

/// Rotation is proved with a 2-second chunk, never by waiting 30 minutes.
final class MixingWriterTests: XCTestCase {

    private var dir: URL!
    private let rate = Int(MixingWriter.sampleRate)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// One second of interleaved stereo float32, the shape SCStream delivers.
    private func oneSecond(value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: MixingWriter.sampleRate,
            channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = AVAudioFrameCount(rate)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0 ..< rate * 2 { samples[i] = value }
        return buffer
    }

    /// Writes `seconds`, lets the writer deallocate to finalize headers, returns the frame count of each file.
    private func write(
        seconds: Int, target: Double = 0, chunkSeconds: Int = 2,
        during: (MixingWriter, Int) -> Void = { _, _ in }
    ) throws -> [(name: String, frames: Int)] {
        var files: [URL] = []
        try autoreleasepool {
            let writer = try MixingWriter(
                outputURL: dir.appendingPathComponent("meeting.wav"),
                targetDurationSeconds: target,
                chunkFrameLimit: chunkSeconds * rate)
            for s in 0 ..< seconds {
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

    func testDefaultChunkIsThirtyMinutes() {
        XCTAssertEqual(MixingWriter.defaultChunkFrameLimit, 30 * 60 * 48_000)
    }

    func testPausedAudioIsDroppedNotSpliced() throws {
        let files = try write(seconds: 3, chunkSeconds: 100) { writer, second in
            if second == 1 || second == 2 { writer.togglePause() }
        }
        XCTAssertEqual(files.map(\.frames), [2 * rate], "the paused second must not reach the file")
    }

    func testFileIsInterleavedMonoInt16() throws {
        let files = try write(seconds: 1)
        let file = try AVAudioFile(forReading: dir.appendingPathComponent(files[0].name))
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }
}
