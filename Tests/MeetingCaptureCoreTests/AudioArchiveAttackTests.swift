import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// The one step that deletes the only full-quality copy. These try to get it to
/// delete a WAV it shouldn't, or to write somewhere it shouldn't.
final class AudioArchiveAttackTests: AudioTestCase {

    private func assertKept(
        _ outcome: AudioArchive.Outcome, wav: URL, file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .archived = outcome { XCTFail("this must not count as proven", file: file, line: line) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "the WAV must stay", file: file, line: line)
    }

    // MARK: Headers a crash can leave

    /// Not a simulated header: a copy taken while the real writer is still open is
    /// exactly what a crash leaves on disk, whatever the OS does about sizes.
    func testACopyOfAWAVStillBeingWrittenIsRescued() throws {
        let live = url("live.wav")
        let copy = url("crashed.wav")
        let writer = try TrackWriter(outputURL: live)
        for _ in 0..<3 {
            TestAudio.pushMic(writer, frames: TestAudio.rate, TestAudio.micTone)
            writer.pushSystem(try TestAudio.stereo(frames: TestAudio.rate, TestAudio.systemTone))
        }
        try FileManager.default.copyItem(at: live, to: copy)
        withExtendedLifetime(writer) {}

        let size = try XCTUnwrap(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(AudioArchive.archive(wav: copy), .archived(m4a: url("crashed.m4a")))
        let seconds = try XCTUnwrap(RecordingFiles.duration(ofAudioAt: url("crashed.m4a").path))
        // 4 bytes a frame. A little may still have been buffered, so judge from the bytes on disk.
        XCTAssertEqual(seconds, Double(size) / 4 / Double(TestAudio.rate), accuracy: 0.5)
    }

    func testASizeOfAllOnesIsRepairedToo() throws {
        let original = try wav("m.wav", seconds: 2)
        try TestAudio.setSizes(of: original, data: 0xFFFF_FFFF, riff: 0xFFFF_FFFF)
        XCTAssertTrue(try WAVRepair.repairHeader(at: original))
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: original.path)), 2, accuracy: 0.01)
    }

    /// Repair picks the data chunk's size from the file's, so check it's what a reader wants.
    func testRepairWritesTheRealSizes() throws {
        let original = try wav("m.wav", seconds: 1)
        let good = try Data(contentsOf: original)
        try TestAudio.crash(original)
        XCTAssertTrue(try WAVRepair.repairHeader(at: original))
        XCTAssertEqual(try Data(contentsOf: original), good, "a repair should match what closing would have written")
    }

    /// A crash can stop partway through a frame.
    func testAWAVCutMidFrameKeepsItsAudio() throws {
        let original = try wav("m.wav", seconds: 2)
        try TestAudio.crash(original)
        var bytes = try Data(contentsOf: original)
        bytes.removeLast(3)
        try bytes.write(to: original)

        let outcome = AudioArchive.archive(wav: original)
        XCTAssertEqual(outcome, .archived(m4a: url("m.m4a")))
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: url("m.m4a").path)), 2, accuracy: 0.5)
    }

    /// Finding 1's neighbour. The tests above it declare zero, which `original > 0` catches
    /// by itself; this is the case only the file-size check stands between us and losing.
    func testAHeaderDeclaringOnlyPartOfTheAudioKeepsTheWAV() throws {
        let original = try wav("m.wav", seconds: 4)
        let quarter = UInt32(TestAudio.rate * 4)
        let riff = quarter + 36
        try TestAudio.setSizes(of: original, data: quarter, riff: riff)
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: original.path)), 1, accuracy: 0.05)

        guard case .keptWAV(let reason) = AudioArchive.archive(wav: original) else {
            return XCTFail("an M4A of the declared second would lose the other three")
        }
        XCTAssertTrue(reason.contains("more audio"), reason)
        XCTAssertTrue(exists("m.wav"))
        XCTAssertFalse(exists("m.m4a"))
    }

    /// Same crash, one step further on: the pipeline transcribes the declared second and
    /// keeps the WAV, and retention must not then delete a file with three untranscribed seconds.
    func testAWAVWithUntranscribedAudioIsNotDeletedByRetention() async throws {
        let original = try wav("m.wav", seconds: 4)
        let quarter = UInt32(TestAudio.rate * 4)
        try TestAudio.setSizes(of: original, data: quarter, riff: quarter + 36)
        let pipeline = RecordingPipeline(transcriber: ScriptedTranscriber(text: "invented words"), detector: nil)
        _ = try await RecordingPipeline.finish(parts: [original], base: url("m"), pipeline: pipeline, now: now)

        let later = now.addingTimeInterval(400 * 86_400)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: later), [])
        XCTAssertTrue(exists("m.wav"), "three seconds of it were never transcribed")
    }

    func testRepairWalksPastAnOddSizedChunkBeforeTheAudio() throws {
        // RIFF, fmt, a 5-byte LIST chunk with its pad byte, then a data chunk declaring nothing.
        var bytes = Data("RIFF".utf8) + TestAudio.littleEndian(0) + Data("WAVE".utf8)
        var format = Data("fmt ".utf8) + TestAudio.littleEndian(16)
        format += Data([1, 0, 1, 0])
        format += TestAudio.littleEndian(48_000) + TestAudio.littleEndian(96_000)
        format += Data([2, 0, 16, 0])
        bytes += format
        bytes += Data("LIST".utf8) + TestAudio.littleEndian(5) + Data([1, 2, 3, 4, 5, 0])
        bytes += Data("data".utf8) + TestAudio.littleEndian(0)
        bytes += Data(repeating: 0, count: 96_000)
        let file = try touch("old.wav", contents: bytes)

        XCTAssertTrue(try WAVRepair.repairHeader(at: file))
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: file.path)), 1, accuracy: 0.01)
    }

    func testAChunkClaimingToRunPastTheFileEndsTheWalkAndChangesNothing() throws {
        let bytes =
            Data("RIFF".utf8) + TestAudio.littleEndian(0) + Data("WAVE".utf8)
            + Data("LIST".utf8) + TestAudio.littleEndian(0xFFFF_FF00) + Data(repeating: 1, count: 32)
        let file = try touch("bad.wav", contents: bytes)
        XCTAssertFalse(try WAVRepair.repairHeader(at: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAFileTooShortToBeAWAVIsLeftAlone() throws {
        let file = try touch("tiny.wav", contents: Data("RIFF".utf8))
        XCTAssertFalse(try WAVRepair.repairHeader(at: file))
    }

    func testRepairingAMissingFileThrowsAndCreatesNothing() {
        XCTAssertThrowsError(try WAVRepair.repairHeader(at: url("gone.wav")))
        XCTAssertFalse(exists("gone.wav"))
    }

    // MARK: Files that can't be changed

    func testACrashedWAVThatCantBeRepairedIsKept() throws {
        let original = try wav("m.wav")
        try TestAudio.crash(original)
        let fragile = try Data(contentsOf: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: original.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original.path) }

        assertKept(AudioArchive.archive(wav: original), wav: original)
        XCTAssertEqual(try Data(contentsOf: original), fragile)
    }

    func testAFolderThatCantBeWrittenKeepsTheWAV() throws {
        let original = try wav("m.wav")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        assertKept(AudioArchive.archive(wav: original), wav: original)
    }

    func testArchivingAMissingWAVReportsItRatherThanClaimingSuccess() {
        guard case .keptWAV = AudioArchive.archive(wav: url("gone.wav")) else {
            return XCTFail("there's nothing to archive")
        }
        XCTAssertFalse(exists("gone.m4a"))
    }

    // MARK: Symlinks at the M4A path (security review, unconfirmed)

    private func outsideFile(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(name)
    }

    func testASymlinkPointingAtAFileIsntWrittenThrough() throws {
        let outside = try outsideFile(named: "target.m4a")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url("m.m4a"), withDestinationURL: outside)
        let original = try wav("m.wav")

        assertKept(AudioArchive.archive(wav: original), wav: original)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }

    /// `fileExists` follows links, so a dangling one looks free.
    func testADanglingSymlinkIsntWrittenThroughAndTheAudioSurvives() throws {
        let outside = try outsideFile(named: "planted.m4a")
        try FileManager.default.createSymbolicLink(at: url("m.m4a"), withDestinationURL: outside)
        let original = try wav("m.wav")

        _ = AudioArchive.archive(wav: original)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "nothing may land outside the folder")
        let m4aIsRealFile =
            (try? FileManager.default.attributesOfItem(atPath: url("m.m4a").path)[.type] as? FileAttributeType)
            == .typeRegular
        XCTAssertTrue(exists("m.wav") || m4aIsRealFile, "the audio must still be here")
    }

    // MARK: Formats --audio-cleanup can meet

    func testAnOlderMonoWAVConvertsToMono() throws {
        let file = url("old.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        try autoreleasepool {
            let out = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: 88_200))
            buffer.frameLength = 88_200
            try out.write(from: buffer)
        }
        XCTAssertEqual(AudioArchive.archive(wav: file), .archived(m4a: url("old.m4a")))
        let converted = try AVAudioFile(forReading: url("old.m4a"))
        XCTAssertEqual(converted.fileFormat.channelCount, 1)
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: url("old.m4a").path)), 2, accuracy: 0.5)
    }

    /// A rate AAC at this bit rate may refuse. Failing is fine; losing the file isn't.
    func testAWAVTheEncoderMayRefuseIsNeverLost() throws {
        let file = url("phone.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true))
        try autoreleasepool {
            let out = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: 8_000))
            buffer.frameLength = 8_000
            try out.write(from: buffer)
        }
        if case .archived(let m4a) = AudioArchive.archive(wav: file) {
            XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: m4a.path)), 1, accuracy: 0.5)
        } else {
            XCTAssertTrue(exists("phone.wav"))
        }
    }

    func testAnM4AKeepsWhichTrackIsWhich() throws {
        let original = try wav("m.wav", seconds: 2, mic: true, system: false)
        XCTAssertEqual(AudioArchive.archive(wav: original), .archived(m4a: url("m.m4a")))
        let split = try AudioTracks.split(url("m.m4a"), into: dir)
        XCTAssertNotNil(split.mic, "recovery can transcribe from an M4A, so channel 1 must still be the mic")
        XCTAssertNil(split.system)
    }
}
