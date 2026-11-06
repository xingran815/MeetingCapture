import AVFoundation
import XCTest

@testable import MeetingCaptureCore

final class AudioCleanupTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func wav(_ name: String, seconds: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
            for _ in 0..<seconds {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
                buffer.frameLength = 48_000
                let out = buffer.floatChannelData![0]
                for i in 0..<96_000 { out[i] = 0.2 * sin(Float(i) * 0.02) }
                writer.pushSystem(buffer)
            }
        }
        return url
    }

    private func answers(_ lines: String...) -> () -> String? {
        var queue = lines
        return { queue.isEmpty ? nil : queue.removeFirst() }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testNoAnswerChangesNothing() throws {
        let old = try wav("old.wav")
        AudioCleanup.run(in: dir, readLine: answers(""))
        XCTAssertTrue(exists(old))
        AudioCleanup.run(in: dir, readLine: answers())
        XCTAssertTrue(exists(old))
    }

    func testDeleteNeedsTheWordTyped() throws {
        let old = try wav("old.wav")
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("d", "y")).deleted, [])
        XCTAssertTrue(exists(old))
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("d", "delete")).deleted.count, 1)
        XCTAssertFalse(exists(old))
    }

    func testConvertLeavesAnM4AAndNoWAV() throws {
        let old = try wav("old.wav")
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("c")).converted.count, 1)
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(dir.appendingPathComponent("old.m4a")))
    }

    func testRecordingsWithASidecarAreLeftAlone() throws {
        let managed = try wav("managed.wav")
        try RecordingSidecar(createdAt: Date(), state: .processed)
            .save(to: RecordingSidecar.url(forBase: dir.appendingPathComponent("managed")))
        AudioCleanup.run(in: dir, readLine: answers("d", "delete"))
        XCTAssertTrue(exists(managed))
    }

    // MARK: Crash recovery

    /// Zeroes the sizes, which is what a file looks like if the writer never closed.
    private func crash(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let marker = try XCTUnwrap(bytes.range(of: Data("data".utf8)))
        bytes.replaceSubrange((marker.upperBound)..<(marker.upperBound + 4), with: Data(count: 4))
        bytes.replaceSubrange(4..<8, with: Data(count: 4))
        try bytes.write(to: url)
    }

    func testACrashedWAVReadsAtFullLengthAfterRepair() throws {
        let url = try wav("crashed.wav", seconds: 2)
        try crash(url)
        XCTAssertTrue(try WAVRepair.repairHeader(at: url))
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: url.path)), 2, accuracy: 0.01)
    }

    func testAHealthyWAVIsNotChanged() throws {
        let url = try wav("fine.wav")
        let before = try Data(contentsOf: url)
        XCTAssertFalse(try WAVRepair.repairHeader(at: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testANonWAVIsNotChanged() throws {
        let url = dir.appendingPathComponent("not.wav")
        let junk = Data(repeating: 7, count: 100)
        try junk.write(to: url)
        XCTAssertFalse(try WAVRepair.repairHeader(at: url))
        XCTAssertEqual(try Data(contentsOf: url), junk)
    }

    // MARK: Speaker names

    func testRenameRejectsAnythingThatWouldBreakTheFormat() {
        XCTAssertEqual(SpeakerLabels.validName("  Ana  "), "Ana")
        XCTAssertNil(SpeakerLabels.validName(""))
        XCTAssertNil(SpeakerLabels.validName("   "))
        XCTAssertNil(SpeakerLabels.validName("a: b"))
        XCTAssertNil(SpeakerLabels.validName("a\nb"))
        XCTAssertEqual(SpeakerLabels.validName("王小明"), "王小明")
    }

    func testRenameUpdatesTheFileAndRemembersItInTheSidecar() throws {
        let base = dir.appendingPathComponent("m")
        let txt = base.appendingPathExtension("txt")
        try "[00:00:01] Speaker 1: hi\n".write(to: txt, atomically: true, encoding: .utf8)
        try RecordingSidecar(createdAt: Date(), state: .processed).save(to: RecordingSidecar.url(forBase: base))

        try SpeakerLabels.rename("Speaker 1", to: "Ana", transcriptAt: txt)

        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), "[00:00:01] Ana: hi\n")
        XCTAssertEqual(
            RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.speakerNames, ["Speaker 1": "Ana"])
    }

    func testDefaultRetentionAndModel() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(config.audioRetentionDays, 30)
        XCTAssertEqual(config.whisperModel, "openai_whisper-small")
    }

    func testAnOutOfRangeRetentionFallsBackToTheDefault() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"audioRetentionDays": 99999}"#.utf8))
        XCTAssertEqual(config.audioRetentionDays, 30)
    }

    func testASavedModelIsKept() throws {
        let config = try JSONDecoder().decode(
            Config.self, from: Data(#"{"whisperModel": "openai_whisper-small.en"}"#.utf8))
        XCTAssertEqual(config.whisperModel, "openai_whisper-small.en")
    }
}
