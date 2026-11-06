import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// One test or more for each finding from M3's deep review and security review, so
/// the same bug can't come back. Fixtures are invented tones.
final class ReviewFindingTests: XCTestCase {

    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func wav(_ name: String = "m.wav", seconds: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            let format = try XCTUnwrap(
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
            for _ in 0..<seconds {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
                buffer.frameLength = 48_000
                let out = try XCTUnwrap(buffer.floatChannelData?[0])
                for i in 0..<96_000 { out[i] = 0.2 * sin(Float(i) * 0.02) }
                writer.pushSystem(buffer)
            }
        }
        return url
    }

    /// What a hard exit leaves: the audio on disk and a header saying there's none.
    private func crash(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let marker = try XCTUnwrap(bytes.range(of: Data("data".utf8)))
        bytes.replaceSubrange((marker.upperBound)..<(marker.upperBound + 4), with: Data(count: 4))
        try bytes.write(to: url)
    }

    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func sidecar(_ base: String, _ value: RecordingSidecar) throws {
        try value.save(to: RecordingSidecar.url(forBase: dir.appendingPathComponent(base)))
    }

    private func processed(ageDays: Double, files: [String]) -> RecordingSidecar {
        let date = now.addingTimeInterval(-ageDays * 86_400)
        return RecordingSidecar(createdAt: date, state: .processed, transcribedAt: date, audioFiles: files)
    }

    private final class Scripted: SpeechTranscribing {
        let segments: [Transcriber.Segment]
        init(_ segments: [Transcriber.Segment]) { self.segments = segments }
        func transcribeSegments(path: String) async throws -> [Transcriber.Segment] { segments }
    }

    private final class OneSpeaker: SpeakerDetecting {
        func detectTurns(path: String) async throws -> [SpeakerTurn] {
            [SpeakerTurn(start: 0, end: 100, speaker: 7)]
        }
    }

    private struct FailingEncoder: AudioEncoding {
        func encode(wav: URL, to m4a: URL) throws { throw CocoaError(.fileWriteOutOfSpace) }
    }

    // MARK: Deep review 1: a crashed WAV passed the proof and was deleted

    func testCrashedWAVWithZeroLengthHeaderIsNeverDeleted() throws {
        let url = try wav(seconds: 3)
        try crash(url)
        XCTAssertEqual(RecordingFiles.duration(ofAudioAt: url.path), 0, "the fixture must read as empty")

        let empty = dir.appendingPathComponent("empty.m4a")
        try autoreleasepool { try AACEncoder().encode(wav: url, to: empty) }
        XCTAssertNotNil(
            AudioArchive.problem(withM4A: empty, comparedTo: url),
            "an empty M4A must never count as proof for a WAV holding audio")
    }

    func testArchivingACrashedWAVKeepsItsAudio() throws {
        let url = try wav(seconds: 3)
        try crash(url)
        XCTAssertEqual(AudioArchive.archive(wav: url), .archived(m4a: dir.appendingPathComponent("m.m4a")))
        let encoded = try XCTUnwrap(RecordingFiles.duration(ofAudioAt: dir.appendingPathComponent("m.m4a").path))
        XCTAssertEqual(encoded, 3, accuracy: 0.5)
    }

    func testAWAVWithNoAudioIsKept() throws {
        let url = dir.appendingPathComponent("silent.wav")
        try autoreleasepool { _ = try TrackWriter(outputURL: url) }
        guard case .keptWAV = AudioArchive.archive(wav: url) else {
            return XCTFail("nothing proves an M4A of no audio is right")
        }
        XCTAssertTrue(exists("silent.wav"))
    }

    // MARK: Deep review 2: a recording running in another process was offered

    func testSidecarHeldByARunningRecordingIsNotOffered() throws {
        _ = try wav()
        var value = RecordingSidecar(createdAt: now, state: .recording)
        value.pid = 4242
        try sidecar("m", value)
        XCTAssertEqual(AudioRetention.unfinished(in: dir, isRunning: { _ in true }), [])
        XCTAssertEqual(
            AudioRetention.unfinished(in: dir, isRunning: { _ in false }).map(\.lastPathComponent), ["m.wav"])
    }

    func testThisProcessCountsAsRunningAndAMissingOneDoesNot() throws {
        XCTAssertTrue(AudioRetention.isRunning(pid: getpid()))
        XCTAssertFalse(AudioRetention.isRunning(pid: 99_999_999))
    }

    func testANewRecordingNamesItsProcessAndFinishingClearsIt() async throws {
        let url = try wav()
        let base = dir.appendingPathComponent("m")
        try RecordingSidecar.started().save(to: RecordingSidecar.url(forBase: base))
        XCTAssertEqual(RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.pid, getpid())
        XCTAssertEqual(AudioRetention.unfinished(in: dir), [], "this very process is still writing it")
        _ = try await RecordingPipeline.finish(parts: [url], base: base, pipeline: nil)
        XCTAssertNil(RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.pid)
    }

    // MARK: Deep review 3: a stop before capture was live hung forever

    func testStopBeforeRunStartsResumesInsteadOfHanging() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.claimStop(), "there's nothing to stop yet")
        XCTAssertTrue(stopper.arm(), "the early stop must be handed back")
        XCTAssertTrue(stopper.claimStop(), "and it must still be able to go through")
        XCTAssertFalse(stopper.claimStop())
    }

    func testAStopAfterArmingGoesThroughOnce() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.arm())
        XCTAssertTrue(stopper.claimStop())
        XCTAssertFalse(stopper.claimStop())
    }

    // MARK: Deep review 4: "processed" didn't mean transcribed

    func testCaptureOnlyRecordingIsNotDeletedByRetention() async throws {
        let base = dir.appendingPathComponent("m")
        _ = try await RecordingPipeline.finish(parts: [try wav()], base: base, pipeline: nil, now: now)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: now.addingTimeInterval(400 * 86_400)), [])
        XCTAssertTrue(exists("m.m4a"))
    }

    func testEmptyTranscriptKeepsAudioPastTheLimit() async throws {
        let base = dir.appendingPathComponent("m")
        let pipeline = RecordingPipeline(transcriber: Scripted([]), detector: nil)
        _ = try await RecordingPipeline.finish(parts: [try wav()], base: base, pipeline: pipeline, now: now)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: now.addingTimeInterval(400 * 86_400)), [])
        XCTAssertTrue(exists("m.m4a"))
    }

    func testATranscribedRecordingStillAgesOut() async throws {
        let base = dir.appendingPathComponent("m")
        let words = Transcriber.Segment(start: 0, end: 1, text: "invented words")
        let pipeline = RecordingPipeline(transcriber: Scripted([words]), detector: nil)
        _ = try await RecordingPipeline.finish(parts: [try wav()], base: base, pipeline: pipeline, now: now)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: now.addingTimeInterval(29 * 86_400)), [])
        let deleted = AudioRetention.clean(in: dir, days: 30, now: now.addingTimeInterval(31 * 86_400))
        XCTAssertEqual(deleted.map(\.lastPathComponent), ["m.m4a"])
    }

    func testRecoveringAnOldRecordingStartsItsRetentionAgain() async throws {
        let base = dir.appendingPathComponent("m")
        try RecordingSidecar(createdAt: now.addingTimeInterval(-90 * 86_400), state: .recording)
            .save(to: RecordingSidecar.url(forBase: base))
        let words = Transcriber.Segment(start: 0, end: 1, text: "invented words")
        let pipeline = RecordingPipeline(transcriber: Scripted([words]), detector: nil)
        _ = try await RecordingPipeline.finish(parts: [try wav()], base: base, pipeline: pipeline, now: now)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: now), [])
    }

    // MARK: Deep review 6 and security review: a sidecar claimed files by name

    func testRetentionLeavesAFileWithItsOwnSidecarAlone() throws {
        _ = try touch("standup.m4a")
        _ = try touch("standup_part2.m4a")
        try sidecar("standup", processed(ageDays: 40, files: ["standup.m4a"]))
        try sidecar("standup_part2", processed(ageDays: 1, files: ["standup_part2.m4a"]))
        let deleted = AudioRetention.clean(in: dir, days: 30, now: now).map(\.lastPathComponent)
        XCTAssertEqual(deleted, ["standup.m4a"])
        XCTAssertTrue(exists("standup_part2.m4a"))
    }

    func testOldFilesWithASimilarNameStayAndStayListedForCleanup() throws {
        _ = try touch("x_part2.wav")
        _ = try touch("x_part3.m4a")
        _ = try touch("x.m4a")
        try sidecar("x", processed(ageDays: 40, files: ["x.m4a"]))
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: now).map(\.lastPathComponent), ["x.m4a"])
        XCTAssertTrue(exists("x_part2.wav"))
        XCTAssertTrue(exists("x_part3.m4a"))
        XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir).map(\.lastPathComponent), ["x_part2.wav"])
    }

    func testASidecarWithoutAFileListDeletesNothing() throws {
        _ = try touch("planted.wav")
        let date = now.addingTimeInterval(-400 * 86_400)
        try sidecar("planted", RecordingSidecar(createdAt: date, state: .processed, transcribedAt: date))
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: now), [])
    }

    func testASidecarCantNameAFileElsewhereOrANonAudioFile() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try touch("notes.txt")
        try sidecar("x", processed(ageDays: 40, files: ["../\(outside.lastPathComponent)", outside.path, "notes.txt"]))
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 30, now: now), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(exists("notes.txt"))
    }

    func testFinishRecordsExactlyTheFilesThatRemain() async throws {
        let base = dir.appendingPathComponent("m")
        let first = try wav()
        let second = try wav("m_part2.wav")
        _ = try await RecordingPipeline.finish(parts: [first, second], base: base, pipeline: nil)
        XCTAssertEqual(
            RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.audioFiles, ["m.m4a", "m_part2.m4a"])
    }

    func testFinishListsAWAVItHadToKeep() async throws {
        let base = dir.appendingPathComponent("m")
        _ = try await RecordingPipeline.finish(parts: [try wav()], base: base, pipeline: nil, encoder: FailingEncoder())
        XCTAssertEqual(RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.audioFiles, ["m.wav"])
    }

    // MARK: Deep review 7: mixed .wav and .m4a parts

    func testAllPartsFindsMixedExtensionsInOrder() throws {
        let first = try touch("m.m4a").path
        let second = try touch("m_part2.wav").path
        let third = try touch("m_part3.m4a").path
        XCTAssertEqual(RecordingFiles.allParts(of: second), [first, second, third])
        XCTAssertEqual(RecordingFiles.allParts(of: dir.appendingPathComponent("m.wav").path), [first, second, third])
    }

    func testThePartAskedForWinsWhenBothFormatsExist() throws {
        let wavPath = try touch("m.wav").path
        let m4aPath = try touch("m.m4a").path
        XCTAssertEqual(RecordingFiles.allParts(of: wavPath), [wavPath])
        XCTAssertEqual(RecordingFiles.allParts(of: m4aPath), [m4aPath])
    }

    func testUnfinishedIsFoundWhenPartOneIsAlreadyM4A() throws {
        _ = try touch("m.m4a")
        _ = try touch("m_part2.wav")
        try sidecar("m", RecordingSidecar(createdAt: now, state: .recording))
        XCTAssertEqual(AudioRetention.unfinished(in: dir).map(\.lastPathComponent), ["m.m4a"])
    }

    func testASidecarWithNoAudioLeftIsNotOffered() throws {
        try sidecar("gone", RecordingSidecar(createdAt: now, state: .recording))
        XCTAssertEqual(AudioRetention.unfinished(in: dir), [])
    }

    // MARK: Deep review 8: colliding names overwrote audio

    func testFailedEncodeLeavesAnExistingM4AAlone() throws {
        let m4a = dir.appendingPathComponent("m.m4a")
        try Data("someone's own file".utf8).write(to: m4a)
        let url = try wav()
        guard case .keptWAV = AudioArchive.archive(wav: url, encoder: FailingEncoder()) else {
            return XCTFail("the encoder failed")
        }
        XCTAssertEqual(try String(contentsOf: m4a, encoding: .utf8), "someone's own file")
        XCTAssertTrue(exists("m.wav"))
    }

    func testAGoodEncodeDoesNotReplaceAnExistingM4A() throws {
        let m4a = dir.appendingPathComponent("m.m4a")
        try Data("someone's own file".utf8).write(to: m4a)
        let url = try wav()
        guard case .keptWAV(let reason) = AudioArchive.archive(wav: url) else {
            return XCTFail("an existing M4A must stop this")
        }
        XCTAssertTrue(reason.contains("already exists"), reason)
        XCTAssertEqual(try String(contentsOf: m4a, encoding: .utf8), "someone's own file")
        XCTAssertTrue(exists("m.wav"))
    }

    func testArchivingLeavesNoTemporaryFilesBehind() throws {
        _ = AudioArchive.archive(wav: try wav())
        _ = AudioArchive.archive(wav: try wav("n.wav"), encoder: FailingEncoder())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["m.m4a", "n.wav"])
    }

    func testOutputOntoAnExistingRecordingIsRefused() throws {
        let base = dir.appendingPathComponent("m")
        XCTAssertNil(RecordingFiles.conflict(forNewRecordingAt: base))
        for name in ["m.wav", "m.m4a", "m_part2.wav", "m_part3.m4a", "m.txt", "m.mcmeta.json"] {
            let url = try touch(name)
            XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: base), name)
            try FileManager.default.removeItem(at: url)
        }
        _ = try touch("m.md")
        _ = try touch("mine.wav")
        XCTAssertNil(RecordingFiles.conflict(forNewRecordingAt: base))
    }

    func testAnOutputNamedLikeALaterPartIsRefused() {
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: dir.appendingPathComponent("standup_part2")))
    }

    func testScriptFlagsNeedAScriptToAskForThem() {
        XCTAssertFalse(AudioFixtures.scriptFlagsEnabled(environment: [:]))
        XCTAssertFalse(AudioFixtures.scriptFlagsEnabled(environment: ["MEETINGCAPTURE_E2E": "0"]))
        XCTAssertTrue(AudioFixtures.scriptFlagsEnabled(environment: ["MEETINGCAPTURE_E2E": "1"]))
    }

    // MARK: Deep review 9: flag mode stopped on any stdin data

    func testAPipeIsNotSomeonePressingEnter() {
        let pipe = Pipe()
        XCTAssertFalse(RecordingKeys.isInteractive(fileDescriptor: pipe.fileHandleForReading.fileDescriptor))
    }

    func testATerminalIs() throws {
        let terminal = posix_openpt(O_RDWR)
        try XCTSkipIf(terminal < 0, "no terminal device is available here")
        defer { close(terminal) }
        XCTAssertTrue(RecordingKeys.isInteractive(fileDescriptor: terminal))
    }

    // MARK: Deep review 10: speaker labels

    func testShortTurnInsideALongTurnDoesNotShortenIt() {
        let merged = SpeakerLabels.mergeShortTurns([
            SpeakerTurn(start: 0, end: 10, speaker: 1),
            SpeakerTurn(start: 3, end: 3.5, speaker: 2),
            SpeakerTurn(start: 10.5, end: 20, speaker: 3),
        ])
        XCTAssertEqual(
            merged, [SpeakerTurn(start: 0, end: 10, speaker: 1), SpeakerTurn(start: 10.5, end: 20, speaker: 3)])
    }

    func testMultiPartTranscriptSaysLabelsAreNotLinked() async throws {
        let segment = Transcriber.Segment(start: 0, end: 1, text: "invented")
        let pipeline = RecordingPipeline(transcriber: Scripted([segment]), detector: OneSpeaker())
        let result = try await pipeline.transcribe(parts: [try wav(), try wav("m_part2.wav")])
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", "Speaker 1 (part 2)"])
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertEqual(SpeakerLabels.speakers(in: result.formatted), ["Speaker 1", "Speaker 1 (part 2)"])
    }

    func testOneRecordingPartNeedsNoNote() async throws {
        let segment = Transcriber.Segment(start: 0, end: 1, text: "invented")
        let pipeline = RecordingPipeline(transcriber: Scripted([segment]), detector: OneSpeaker())
        let result = try await pipeline.transcribe(parts: [try wav()])
        XCTAssertEqual(result.notes, [])
    }

    func testOthersHasNoPartMarker() {
        let segment = LabelledSegment(start: 0, end: 1, speaker: SpeakerLabels.others, text: "x")
        XCTAssertEqual(SpeakerLabels.markPart(segment, number: 2).speaker, SpeakerLabels.others)
    }

    // MARK: Deep review 5: noise picked the language

    func testTheLoudestWindowIsWhereTheSpeechIs() {
        var samples = [Float](repeating: 0.001, count: 100)
        for i in 60..<70 { samples[i] = 0.5 }
        let window = Transcriber.loudestWindow(in: samples, length: 20, step: 5)
        XCTAssertEqual(window.count, 20)
        XCTAssertTrue(window.contains(60) && window.contains(69), "\(window)")
    }

    func testShortOrSilentAudioUsesTheStart() {
        XCTAssertEqual(Transcriber.loudestWindow(in: [0.1, 0.2], length: 20, step: 5), 0..<2)
        XCTAssertEqual(Transcriber.loudestWindow(in: [Float](repeating: 0, count: 100), length: 20, step: 5), 0..<20)
    }

    func testSteadyQuietNoiseCountsAsNoSpeech() {
        // Exactly the fewest windows (50 of 100 ms, which is 5 s) is enough to judge.
        XCTAssertEqual(AudioTracks.fewestWindows, 50)
        let steady = [Float](repeating: 0.002, count: 50)
        XCTAssertTrue(AudioTracks.isSteadyQuietNoise(levels: steady))
    }

    func testQuietSpeechIsNeverTakenForNoise() {
        var levels = [Float](repeating: 0.002, count: 50)
        levels[30] = 0.0045  // still quiet, but not steady
        XCTAssertFalse(AudioTracks.isSteadyQuietNoise(levels: levels))
    }

    func testSteadyLoudSoundIsNeverTakenForNoise() {
        XCTAssertFalse(AudioTracks.isSteadyQuietNoise(levels: [Float](repeating: 0.05, count: 50)))
    }

    func testTooLittleAudioToJudgeIsKept() {
        XCTAssertFalse(AudioTracks.isSteadyQuietNoise(levels: [Float](repeating: 0.002, count: 49)))
    }

    /// Real file, real split: noise on the mic, a loud tone on the system track.
    func testANoisyMicTrackIsTranscribedFlaggedAndTheUserIsTold() async throws {
        let url = dir.appendingPathComponent("noisy.wav")
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            let format = try XCTUnwrap(
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<8 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
                buffer.frameLength = 48_000
                let out = try XCTUnwrap(buffer.floatChannelData?[0])
                let noise = (0..<48_000).map { _ in Float.random(in: -0.003...0.003, using: &generator) }
                for i in 0..<96_000 { out[i] = 0.2 * sin(Float(i) * 0.02) }
                noise.withUnsafeBufferPointer { writer.pushMic(mono: $0.baseAddress!, frameCount: 48_000) }
                writer.pushSystem(buffer)
            }
        }
        let split = try AudioTracks.split(url, into: try workFolder())
        XCTAssertNotNil(split.mic, "a noise-like track is still returned for transcription")
        XCTAssertEqual(split.soundsLikeNoise, ["mic"])
        let transcriber = ScriptedTranscriber(text: "invented")
        let pipeline = RecordingPipeline(transcriber: transcriber, detector: OneSpeaker())
        let result = try await pipeline.transcribe(parts: [url])
        XCTAssertTrue(transcriber.paths.contains { $0.hasSuffix(".mic.wav") }, "\(transcriber.paths)")
        XCTAssertEqual(
            result.segments.map(\.speaker).sorted(), ["Speaker 1", "You"], "the mic lines are labelled as usual")
        XCTAssertTrue(result.hasDoubtfulTrack)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes[0].contains("mic"), result.notes[0])
        XCTAssertTrue(result.notes[0].contains("may be invented"), result.notes[0])
    }

    func testNoiseMarkersAreDroppedAndRealOnesStay() {
        for marker in ["[BLANK_AUDIO]", "(blank_audio)", "[ Silence ]", "[", "(silence)", "[no audio]", "[NO SPEECH]"] {
            XCTAssertTrue(SpeakerLabels.isSilenceMarker(marker), marker)
        }
        for real in ["[laughter]", "[Music]", "silence is golden", "Hello"] {
            XCTAssertFalse(SpeakerLabels.isSilenceMarker(real), real)
        }
    }

    /// The marker words are removed from the text before the rest is judged, so text that
    /// only contains them next to real words must be left with those words, and kept.
    func testMarkerWordsBesideRealWordsAreNotSilence() {
        for text in [
            "[silence please]", "(no speech today)", "[BLANK_AUDIO] thanks", "(no audio) hello",
            "[silence] and then he left",
            "[no audio recording]", "[silenced]", "[silence 5]", "(no speech detected)", "[NO NO SPEECH SPEECH]",
            "[SILEN NO SPEECH CE]", "[silence, then applause]",
        ] {
            XCTAssertFalse(SpeakerLabels.isSilenceMarker(text), text)
        }
        for text in ["[silence...]", "(No Speech.)", "[silence] [silence]", "  [BLANK_AUDIO]  "] {
            XCTAssertTrue(SpeakerLabels.isSilenceMarker(text), text)
        }
    }

    func testAFormattedTranscriptKeepsALineWhoseBracketHoldsRealWords() {
        let segments = [
            LabelledSegment(start: 1, end: 2, speaker: "You", text: "[silence please]"),
            LabelledSegment(start: 3, end: 4, speaker: "You", text: "[BLANK_AUDIO]"),
        ]
        XCTAssertEqual(SpeakerLabels.format(segments), "[00:00:01] You: [silence please]")
    }

    // MARK: Deep-review re-check: retention could delete audio that was never transcribed

    /// A deterministic, white-ish noise sample for index `i`, uniform in ±`amplitude`.
    /// Hash-based so the same index always gives the same value and no run can flake.
    private static func noise(_ i: Int, amplitude: Float) -> Float {
        var x = UInt32(truncatingIfNeeded: i) &+ 0x9E37_79B9
        x = (x ^ (x >> 16)) &* 0x85EB_CA6B
        x = (x ^ (x >> 13)) &* 0xC2B2_AE35
        x ^= x >> 16
        return (Float(x) / Float(UInt32.max) * 2 - 1) * amplitude
    }

    /// Uniform noise has an RMS of amplitude / sqrt(3), so this is RMS `rms`.
    private static func amplitude(forRMS rms: Float) -> Float { rms * Float(3).squareRoot() }

    /// RMS 0.002: quiet steady noise.
    private static let steadyNoise: (Int) -> Float = { noise($0, amplitude: amplitude(forRMS: 0.002)) }

    private func twoTrack(_ name: String, seconds: Double, mic: ((Int) -> Float)?, system: ((Int) -> Float)?) throws
        -> URL
    {
        let url = dir.appendingPathComponent(name)
        try TestAudio.writeWAV(at: url, seconds: seconds, mic: mic, system: system)
        return url
    }

    private func finishRecording(_ parts: [URL]) async throws -> RecordingPipeline.Transcript? {
        let transcriber = ScriptedTranscriber(text: "invented words")
        return try await RecordingPipeline.finish(
            parts: parts, base: dir.appendingPathComponent("m"),
            pipeline: RecordingPipeline(transcriber: transcriber, detector: nil), now: now)
    }

    private func savedSidecar() -> RecordingSidecar? {
        RecordingSidecar.load(at: RecordingSidecar.url(forBase: dir.appendingPathComponent("m")))
    }

    private func deletedByRetentionFarInTheFuture() -> [String] {
        AudioRetention.clean(in: dir, days: 1, now: now.addingTimeInterval(400 * 86_400)).map(\.lastPathComponent)
    }

    /// Finding "retention can delete audio that was never transcribed": a mic track that sounds
    /// like noise could be soft speech, so the recording must not become eligible for deletion.
    func testATrackThatSoundsLikeNoiseKeepsTheAudioOutOfRetention() async throws {
        let part = try twoTrack("m.wav", seconds: 6, mic: Self.steadyNoise, system: TestAudio.systemTone)
        let result = try await finishRecording([part])
        let transcript = try XCTUnwrap(result)
        XCTAssertTrue(transcript.formatted.contains("invented words"), "the system track has words")
        XCTAssertTrue(transcript.hasDoubtfulTrack)
        XCTAssertTrue(
            transcript.notes.contains { $0.contains("won't be deleted automatically") }, "\(transcript.notes)")
        let saved = try XCTUnwrap(savedSidecar())
        XCTAssertEqual(saved.state, .processed)
        XCTAssertNil(
            saved.transcribedAt,
            "a track sounded like noise, so its lines are doubtful and the audio isn't proven transcribed")
        let files = try XCTUnwrap(saved.audioFiles)
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(deletedByRetentionFarInTheFuture(), [])
        for name in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
    }

    func testNoiseInOnlyThePartTwoMicTrackAlsoKeepsTheWholeRecording() async throws {
        let one = try twoTrack("m.wav", seconds: 6, mic: nil, system: TestAudio.systemTone)
        let two = try twoTrack("m_part2.wav", seconds: 6, mic: Self.steadyNoise, system: TestAudio.systemTone)
        let result = try await finishRecording([one, two])
        let transcript = try XCTUnwrap(result)
        XCTAssertTrue(transcript.hasDoubtfulTrack)
        XCTAssertNil(try XCTUnwrap(savedSidecar()).transcribedAt)
        XCTAssertEqual(deletedByRetentionFarInTheFuture(), [])
    }

    /// The control: the same setup without a noise track is transcribed and eligible, so
    /// the two tests above can't pass just because nothing ever sets `transcribedAt`.
    func testTheSameRecordingWithNoNoiseTrackIsMarkedTranscribedAndEligible() async throws {
        let part = try twoTrack("m.wav", seconds: 6, mic: nil, system: TestAudio.systemTone)
        let result = try await finishRecording([part])
        let transcript = try XCTUnwrap(result)
        XCTAssertFalse(transcript.hasDoubtfulTrack)
        XCTAssertEqual(try XCTUnwrap(savedSidecar()).transcribedAt, now)
        XCTAssertFalse(deletedByRetentionFarInTheFuture().isEmpty, "this one may be deleted once old")
    }

    // MARK: Deep-review re-check: soft speech passed as noise

    /// Quiet speech-like audio: a 0.002-RMS floor, plus 150 ms bursts 4 times a second for 1.2 s
    /// of every 3 s, with a pause between phrases. Each burst adds 0.0042 RMS on top of the floor.
    private static let softSpeech: (Int) -> Float = { i in
        let ms = (i * 1000 / 48_000) % 3_000
        let floor = noise(i, amplitude: amplitude(forRMS: 0.002))
        guard ms < 1_200, ms % 250 < 150 else { return floor }
        return floor + noise(i &+ 7_919, amplitude: amplitude(forRMS: 0.0042))
    }

    private func rmsLevels(_ samples: [Float], window: Int) -> [Float] {
        stride(from: 0, to: samples.count - window + 1, by: window).map { start in
            let energy = samples[start..<(start + window)].reduce(Float(0)) { $0 + $1 * $1 }
            return (energy / Float(window)).squareRoot()
        }
    }

    private func workFolder() throws -> URL {
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    func testSoftSpeechThatTheOldSecondLongMeasureCalledNoiseIsStillTranscribed() throws {
        let part = try twoTrack("soft.wav", seconds: 12, mic: Self.softSpeech, system: nil)
        let samples = try TestAudio.tracks(of: part).mic

        // The old measure: one-second levels, all under 0.005 and varying by under 2x.
        let seconds = rmsLevels(samples, window: 48_000)
        let median = seconds.sorted()[seconds.count / 2]
        let loudestSecond = try XCTUnwrap(seconds.max())
        XCTAssertLessThan(loudestSecond, AudioTracks.quietLevel, "\(seconds)")
        XCTAssertLessThan(loudestSecond, median * AudioTracks.steadyRatio, "\(seconds)")
        // The new measure sees the words apart from the pauses.
        let windows = rmsLevels(samples, window: AudioTracks.levelWindowFrames)
        XCTAssertGreaterThanOrEqual(windows.count, AudioTracks.fewestWindows)
        XCTAssertFalse(AudioTracks.isSteadyQuietNoise(levels: windows))

        let split = try AudioTracks.split(part, into: try workFolder())
        XCTAssertNotNil(split.mic, "the soft speech must go to transcription")
        XCTAssertEqual(split.soundsLikeNoise, [])
    }

    func testSteadyNoiseAtTheSameLevelIsReturnedAndListedAsSoundingLikeNoise() throws {
        let part = try twoTrack("steady.wav", seconds: 10, mic: Self.steadyNoise, system: nil)
        let split = try AudioTracks.split(part, into: try workFolder())
        XCTAssertNotNil(split.mic, "D-56: it is still transcribed")
        XCTAssertEqual(split.soundsLikeNoise, ["mic"])
    }

    func testLessThanFiveSecondsIsNeverCalledNoise() throws {
        let work = try workFolder()
        // 4.9 s is 49 windows of 100 ms: one short of enough. 5 s is exactly enough.
        let short = try twoTrack("short.wav", seconds: 4.9, mic: Self.steadyNoise, system: nil)
        let shortSplit = try AudioTracks.split(short, into: work)
        XCTAssertNotNil(shortSplit.mic)
        XCTAssertEqual(shortSplit.soundsLikeNoise, [])
        let enough = try twoTrack("enough.wav", seconds: 5, mic: Self.steadyNoise, system: nil)
        XCTAssertEqual(try AudioTracks.split(enough, into: work).soundsLikeNoise, ["mic"])
    }

    // MARK: D-56: soft speech over a noise floor was left out

    /// Speech-like bursts: 150 ms on, 100 ms off, for 1.2 s of every 3 s. Tuned so the
    /// loudest 100 ms window measures about 0.004, over a 0.002 noise floor.
    private static let burstsOverFloor: (Int) -> Float = { i in
        let ms = (i * 1000 / 48_000) % 3_000
        let floor = noise(i, amplitude: amplitude(forRMS: 0.002))
        guard ms < 1_200, ms % 250 < 150 else { return floor }
        return floor + 0.0035 * sin(Float(i) * 0.05)
    }

    /// Finding "soft speech over a noise floor was left out": it is transcribed, the words
    /// reach the text, the note says they may be invented, and the audio is never deleted.
    func testSoftSpeechOverANoiseFloorWasLeftOutIsNowTranscribedAndFlagged() async throws {
        let part = try twoTrack("m.wav", seconds: 12, mic: Self.burstsOverFloor, system: nil)
        let samples = try TestAudio.tracks(of: part).mic
        let loudest = try XCTUnwrap(rmsLevels(samples, window: AudioTracks.levelWindowFrames).max())
        XCTAssertGreaterThan(loudest, 0.003, "the fixture's loudest window must be about 0.004")
        XCTAssertLessThan(loudest, 0.005, "\(loudest)")

        let split = try AudioTracks.split(part, into: try workFolder())
        XCTAssertNotNil(split.mic, "the soft speech must go to transcription")
        XCTAssertNil(split.system)

        let transcriber = ScriptedTranscriber { path in
            path.hasSuffix(".mic.wav") ? [Transcriber.Segment(start: 0.5, end: 1, text: "budget review tomorrow")] : []
        }
        let result = try await RecordingPipeline.finish(
            parts: [part], base: dir.appendingPathComponent("m"),
            pipeline: RecordingPipeline(transcriber: transcriber, detector: nil), now: now)
        let transcript = try XCTUnwrap(result)
        XCTAssertTrue(transcriber.paths.contains { $0.hasSuffix(".mic.wav") }, "\(transcriber.paths)")
        let text = try String(contentsOf: dir.appendingPathComponent("m.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("You: budget review tomorrow"), text)
        XCTAssertTrue(transcript.hasDoubtfulTrack)
        XCTAssertTrue(transcript.notes.contains { $0.contains("may be invented") }, "\(transcript.notes)")
        XCTAssertNil(try XCTUnwrap(savedSidecar()).transcribedAt)
        XCTAssertEqual(deletedByRetentionFarInTheFuture(), [])
    }

    /// Finding "soft speech over a noise floor was left out": the note names only the track
    /// that sounds like noise.
    func testOnlyTheNoiseLikeTrackIsListedWhenTheOtherIsClean() throws {
        let part = try twoTrack("m.wav", seconds: 8, mic: Self.steadyNoise, system: TestAudio.systemTone)
        let split = try AudioTracks.split(part, into: try workFolder())
        XCTAssertEqual(split.soundsLikeNoise, ["mic"])
        XCTAssertNotNil(split.mic)
        XCTAssertNotNil(split.system)
    }

    func testTheNoteAppearsOnlyForTheTrackThatSoundsLikeNoise() async throws {
        let part = try twoTrack("m.wav", seconds: 8, mic: Self.steadyNoise, system: TestAudio.systemTone)
        let result = try await RecordingPipeline(transcriber: ScriptedTranscriber(text: "words"), detector: nil)
            .transcribe(parts: [part])
        let doubtful = result.notes.filter { $0.contains("may be invented") }
        XCTAssertEqual(doubtful.count, 1, "\(result.notes)")
        XCTAssertTrue(doubtful[0].contains("the mic track"), doubtful[0])
        XCTAssertFalse(doubtful[0].contains("system audio"), doubtful[0])
    }

    /// A truly silent track (all zeros) is not noise-like: it is skipped, and there's no note.
    func testATrulySilentTrackIsNotTranscribedAndNotListedAsNoise() async throws {
        let part = try twoTrack("m.wav", seconds: 8, mic: { _ in 0 }, system: TestAudio.systemTone)
        let split = try AudioTracks.split(part, into: try workFolder())
        XCTAssertNil(split.mic)
        XCTAssertNotNil(split.system)
        XCTAssertEqual(split.soundsLikeNoise, [])
        let transcriber = ScriptedTranscriber(text: "words")
        let result = try await RecordingPipeline(transcriber: transcriber, detector: nil).transcribe(parts: [part])
        XCTAssertFalse(transcriber.paths.contains { $0.hasSuffix(".mic.wav") }, "\(transcriber.paths)")
        XCTAssertFalse(result.hasDoubtfulTrack)
        XCTAssertTrue(result.notes.filter { $0.contains("invented") }.isEmpty, "\(result.notes)")
    }

    // MARK: Deep-review re-check: API key temp file was briefly readable

    private func withKeyFile<T>(_ body: (URL) throws -> T) rethrows -> T {
        let file = dir.appendingPathComponent("keys", isDirectory: true).appendingPathComponent("keys.json")
        APIKeyStore.pathOverride = file
        defer { APIKeyStore.pathOverride = nil }
        return try body(file)
    }

    private final class ModeWatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var looked = 0
        private var loose: [String] = []
        private let folder: String

        init(folder: String) { self.folder = folder }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        private var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func run() {
            while !isStopped {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
                for name in names where name.hasSuffix(".tmp") {
                    var info = stat()
                    // A file moved or deleted between listing and stat isn't a finding.
                    guard lstat(folder + "/" + name, &info) == 0 else { continue }
                    lock.lock()
                    looked += 1
                    if info.st_mode & 0o077 != 0 { loose.append("\(name): \(String(info.st_mode & 0o777, radix: 8))") }
                    lock.unlock()
                }
            }
        }

        var report: (looked: Int, loose: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (looked, loose)
        }
    }

    /// Finding "API key temp file is briefly readable". The watcher only fails when it catches a
    /// loose file, so the correct code can't make it flake. How often it catches the old code
    /// depends on timing, so many writes of a growing file give it many chances.
    func testTheKeyTempFileIsNeverReadableByOthersWhileItExists() throws {
        try withKeyFile { file in
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let watcher = ModeWatcher(folder: folder.path)
            let thread = Thread { watcher.run() }
            thread.start()
            let bigValue = String(repeating: "fake-key-", count: 200)
            for i in 0..<400 {
                XCTAssertTrue(APIKeyStore.write(bigValue + "\(i)", forProfile: "profile-\(i)"))
            }
            watcher.stop()
            let report = watcher.report
            XCTAssertEqual(report.loose, [], "a temp file was readable by group or others (\(report.looked) looked at)")
            XCTAssertEqual(APIKeyStore.read(profileID: "profile-399"), bigValue + "399")
        }
    }

    func testTheKeyFileEndsPrivateAndLeavesNoTempFileBehind() throws {
        try withKeyFile { file in
            XCTAssertTrue(APIKeyStore.write("fake-key", forProfile: "a"))
            XCTAssertTrue(APIKeyStore.write("fake-key-2", forProfile: "b"))
            XCTAssertTrue(APIKeyStore.delete(profileID: "a"))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
            let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            XCTAssertEqual(names, ["keys.json"])
            XCTAssertEqual(APIKeyStore.read(profileID: "b"), "fake-key-2")
        }
    }

    func testWritingAKeyFailsSafelyWhenTheFolderIsNotWritable() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores folder permissions")
        try withKeyFile { file in
            let folder = file.deletingLastPathComponent()
            XCTAssertTrue(APIKeyStore.write("fake-key", forProfile: "a"))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            XCTAssertFalse(APIKeyStore.write("other-key", forProfile: "b"))
            XCTAssertEqual(APIKeyStore.read(profileID: "a"), "fake-key", "the earlier key survives")
            XCTAssertNil(APIKeyStore.read(profileID: "b"))
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(names, ["keys.json"], "no temp file left")
        }
    }

    // MARK: Deep-review re-check: a corrupt config was lost on the first Settings change

    private func writeConfig(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("config.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func folderNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testACorruptConfigIsCopiedBeforeTheNextSaveReplacesIt() throws {
        let original = #"{"llmProfiles": [ {"id": "mine", "name": "typo here" ,,}"#
        let url = try writeConfig(original)
        let config = Config.load(at: url, legacyURL: nil)
        XCTAssertEqual(config.audioRetentionDays, 0, "unsure what they chose, so delete nothing")
        try config.save(to: url)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt")), Data(original.utf8))
        XCTAssertNotEqual(try Data(contentsOf: url), Data(original.utf8), "the save replaced the original")
    }

    func testTheSameCorruptBytesAreNotCopiedTwiceAndDifferentOnesGetANewNumber() throws {
        let first = "{ first typo"
        let url = try writeConfig(first)
        _ = Config.load(at: url, legacyURL: nil)
        _ = try writeConfig(first)
        _ = Config.load(at: url, legacyURL: nil)
        XCTAssertEqual(try folderNames(), ["config.json", "config.json.corrupt"])

        let second = "{ second typo"
        _ = try writeConfig(second)
        _ = Config.load(at: url, legacyURL: nil)
        XCTAssertEqual(try folderNames(), ["config.json", "config.json.corrupt", "config.json.corrupt2"])
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: url.path + ".corrupt"), encoding: .utf8), first)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: url.path + ".corrupt2"), encoding: .utf8), second)

        // The second bytes again reuse their copy.
        _ = try writeConfig(second)
        _ = Config.load(at: url, legacyURL: nil)
        XCTAssertEqual(try folderNames(), ["config.json", "config.json.corrupt", "config.json.corrupt2"])
    }

    func testAGoodConfigMakesNoCopy() throws {
        let url = dir.appendingPathComponent("config.json")
        try Config().save(to: url)
        _ = Config.load(at: url, legacyURL: nil)
        XCTAssertEqual(try folderNames(), ["config.json"])
        try FileManager.default.removeItem(at: url)
        _ = Config.load(at: url, legacyURL: nil)
        XCTAssertEqual(try folderNames(), [], "a missing file makes no copy either")
    }
}
