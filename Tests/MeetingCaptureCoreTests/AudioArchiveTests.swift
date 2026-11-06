import AVFoundation
import XCTest

@testable import MeetingCaptureCore

final class AudioArchiveTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// A two-track WAV through the real writer: a tone in each named channel.
    private func twoTrackWAV(seconds: Int = 2, mic: Bool = true, system: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent("meeting.wav")
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            let rate = Int(TrackWriter.sampleRate)
            let format = try XCTUnwrap(
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
            for _ in 0..<seconds {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
                buffer.frameLength = AVAudioFrameCount(rate)
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                var tone = [Float](repeating: 0, count: rate)
                for i in 0..<rate {
                    tone[i] = 0.25 * sin(Float(i) * 0.05)
                    samples[2 * i] = system ? 0.5 * sin(Float(i) * 0.03) : 0
                    samples[2 * i + 1] = samples[2 * i]
                }
                if mic { tone.withUnsafeBufferPointer { writer.pushMic(mono: $0.baseAddress!, frameCount: rate) } }
                writer.pushSystem(buffer)
            }
        }
        return url
    }

    private struct FailingEncoder: AudioEncoding {
        func encode(wav: URL, to m4a: URL) throws { throw CocoaError(.fileWriteOutOfSpace) }
    }

    private struct EmptyEncoder: AudioEncoding {
        func encode(wav: URL, to m4a: URL) throws { try Data().write(to: m4a) }
    }

    /// Writes a real M4A of the first half only, so the length check has to catch it.
    private struct TruncatingEncoder: AudioEncoding {
        func encode(wav: URL, to m4a: URL) throws {
            let input = try AVAudioFile(forReading: wav)
            let output = try AVAudioFile(
                forWriting: m4a,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ], commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
            let half = AVAudioFrameCount(input.length / 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: half)!
            try input.read(into: buffer, frameCount: half)
            try output.write(from: buffer)
        }
    }

    // MARK: Writer

    func testFileHasTwoTracks() throws {
        let file = try AVAudioFile(forReading: try twoTrackWAV(seconds: 1))
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }

    func testMicIsChannelOneAndSystemIsChannelTwo() throws {
        let micOnly = try twoTrackWAV(system: false)
        let split = try AudioTracks.split(micOnly, into: dir)
        XCTAssertNotNil(split.mic)
        XCTAssertNil(split.system, "no system audio was written, so channel 2 must be silent")

        try FileManager.default.removeItem(at: micOnly)
        let systemOnly = try AudioTracks.split(try twoTrackWAV(mic: false), into: dir)
        XCTAssertNil(systemOnly.mic, "no mic audio was written, so channel 1 must be silent")
        XCTAssertNotNil(systemOnly.system)
    }

    func testSplitTracksKeepTheFullLength() throws {
        let split = try AudioTracks.split(try twoTrackWAV(seconds: 2), into: dir)
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: split.mic!.path)), 2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: split.system!.path)), 2, accuracy: 0.01)
    }

    func testAnOlderMonoFileCountsAsSystemAudio() throws {
        let url = dir.appendingPathComponent("old.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
            buffer.frameLength = 4800
            try file.write(from: buffer)
        }
        let split = try AudioTracks.split(url, into: dir)
        XCTAssertNil(split.mic)
        XCTAssertEqual(split.system, url)
    }

    // MARK: M4A

    func testGoodConversionReplacesTheWAVAndIsAtLeast8xSmaller() throws {
        let wav = try twoTrackWAV(seconds: 10)
        let wavSize = try XCTUnwrap(try wav.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let outcome = AudioArchive.archive(wav: wav)
        let m4a = dir.appendingPathComponent("meeting.m4a")
        XCTAssertEqual(outcome, .archived(m4a: m4a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        let m4aSize = try XCTUnwrap(try m4a.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThanOrEqual(wavSize, 8 * m4aSize)
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: m4a.path)), 10, accuracy: 0.5)
        XCTAssertEqual(try AVAudioFile(forReading: m4a).fileFormat.channelCount, 2)
    }

    func testFailedConversionKeepsTheWAV() throws {
        let wav = try twoTrackWAV()
        guard case .keptWAV = AudioArchive.archive(wav: wav, encoder: FailingEncoder()) else {
            return XCTFail("a failed conversion must keep the WAV")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    func testEmptyM4AKeepsTheWAVAndIsRemoved() throws {
        let wav = try twoTrackWAV()
        XCTAssertEqual(AudioArchive.archive(wav: wav, encoder: EmptyEncoder()), .keptWAV(reason: "the M4A is empty"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.m4a").path))
    }

    func testShortM4AKeepsTheWAV() throws {
        let wav = try twoTrackWAV(seconds: 4)
        guard case .keptWAV(let reason) = AudioArchive.archive(wav: wav, encoder: TruncatingEncoder()) else {
            return XCTFail("a truncated M4A must keep the WAV")
        }
        XCTAssertTrue(reason.contains("long"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    // MARK: Retention

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func recording(_ base: String, ageDays: Double, state: RecordingSidecar.State = .processed) throws {
        for name in ["\(base).m4a", "\(base)_part2.m4a", "\(base).txt", "\(base).md", "\(base).html"] {
            XCTAssertTrue(
                FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()))
        }
        let date = now.addingTimeInterval(-ageDays * 86_400)
        var sidecar = RecordingSidecar(createdAt: date, state: state)
        if state == .processed {
            sidecar.transcribedAt = date
            sidecar.audioFiles = ["\(base).m4a", "\(base)_part2.m4a"]
        }
        try sidecar.save(to: RecordingSidecar.url(forBase: dir.appendingPathComponent(base)))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testOlderManagedAudioGoesAndYoungerStays() throws {
        try recording("old", ageDays: 31)
        try recording("young", ageDays: 29)
        let deleted = AudioRetention.clean(in: dir, days: 30, now: now).map(\.lastPathComponent)
        XCTAssertEqual(deleted, ["old.m4a", "old_part2.m4a"])
        XCTAssertTrue(exists("young.m4a"))
    }

    func testRetentionCoversAudioOnly() throws {
        try recording("old", ageDays: 31)
        AudioRetention.clean(in: dir, days: 30, now: now)
        for kept in ["old.txt", "old.md", "old.html", "old.mcmeta.json"] { XCTAssertTrue(exists(kept), kept) }
    }

    func testOldUnmanagedWAVsStay() throws {
        let wav = dir.appendingPathComponent("from_2024.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: wav.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: wav.path)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: now), [])
        XCTAssertTrue(exists("from_2024.wav"))
        XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir).map(\.lastPathComponent), ["from_2024.wav"])
    }

    func testZeroKeepsForever() throws {
        try recording("old", ageDays: 5000)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 0, now: now), [])
    }

    func testUnreadableSidecarKeepsTheAudio() throws {
        XCTAssertTrue(
            FileManager.default.createFile(atPath: dir.appendingPathComponent("x.m4a").path, contents: Data()))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("x.mcmeta.json"))
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: now), [])
    }

    func testAnUnfinishedRecordingIsNeverDeletedAndIsOfferedForProcessing() throws {
        try recording("crashed", ageDays: 400, state: .recording)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: dir.appendingPathComponent("crashed.wav").path, contents: Data()))
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: now), [])
        XCTAssertEqual(AudioRetention.unfinished(in: dir).map(\.lastPathComponent), ["crashed.wav"])
    }

    func testRetentionLimits() {
        for valid in [0, 1, 30, 3650] { XCTAssertTrue(AudioRetention.isValid(days: valid)) }
        for invalid in [-1, 3651] { XCTAssertFalse(AudioRetention.isValid(days: invalid)) }
    }
}
