import AVFoundation
import XCTest

@testable import MeetingCaptureCore

final class SpeakerLabelsTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double, _ text: String, words: [Transcriber.Word] = [])
        -> Transcriber.Segment
    {
        Transcriber.Segment(start: start, end: end, text: text, words: words)
    }

    func testMostOverlapWins() {
        let turns = [SpeakerTurn(start: 0, end: 2, speaker: 7), SpeakerTurn(start: 2, end: 10, speaker: 3)]
        let out = SpeakerLabels.label([segment(1, 6, "hello")], turns: turns)
        XCTAssertEqual(out.map(\.speaker), ["Speaker 2"])
    }

    func testSpeakersAreNumberedInTheOrderTheyTalk() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 9), SpeakerTurn(start: 5, end: 10, speaker: 2)]
        let out = SpeakerLabels.label([segment(0, 4, "a"), segment(6, 9, "b")], turns: turns)
        XCTAssertEqual(out.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testASegmentSpanningTwoSpeakersSplitsAtWordTimestamps() {
        let turns = [SpeakerTurn(start: 0, end: 3, speaker: 0), SpeakerTurn(start: 3, end: 6, speaker: 1)]
        let words = [
            Transcriber.Word(start: 0, end: 1, text: " one"), Transcriber.Word(start: 1, end: 2.5, text: " two"),
            Transcriber.Word(start: 3.2, end: 4, text: " three"), Transcriber.Word(start: 4, end: 5, text: " four"),
        ]
        let out = SpeakerLabels.label([segment(0, 5, " one two three four", words: words)], turns: turns)
        XCTAssertEqual(out.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(out.map(\.text), [" one two", " three four"])
        XCTAssertEqual(out.map(\.start), [0, 3.2])
    }

    func testAStray600msSpeakerJoinsANeighbourAndGetsNoNumber() {
        let turns = [
            SpeakerTurn(start: 0, end: 10, speaker: 0), SpeakerTurn(start: 10, end: 20, speaker: 1),
            SpeakerTurn(start: 20, end: 20.6, speaker: 2),
        ]
        let merged = SpeakerLabels.mergeShortTurns(turns)
        XCTAssertEqual(merged.map(\.speaker), [0, 1])
        XCTAssertEqual(merged.last?.end, 20.6)
        let out = SpeakerLabels.label([segment(20.1, 20.5, "bye")], turns: turns)
        XCTAssertEqual(out.map(\.speaker), ["Speaker 2"])
    }

    func testAShortTurnAtTheStartGoesToTheNextSpeaker() {
        let merged = SpeakerLabels.mergeShortTurns([
            SpeakerTurn(start: 0, end: 0.4, speaker: 5), SpeakerTurn(start: 0.4, end: 9, speaker: 1),
        ])
        XCTAssertEqual(merged, [SpeakerTurn(start: 0, end: 9, speaker: 1)])
    }

    func testASegmentInAGapGoesToTheClosestTurn() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 20, end: 25, speaker: 1)]
        XCTAssertEqual(SpeakerLabels.label([segment(18, 19, "x")], turns: turns).map(\.speaker), ["Speaker 2"])
    }

    func testNoTurnsMeansOthers() {
        XCTAssertEqual(SpeakerLabels.label([segment(0, 1, "x")], turns: []).map(\.speaker), ["Others"])
    }

    func testFormatMatchesTheSpecAndStripsSpecialTokens() {
        let line = LabelledSegment(
            start: 72, end: 75, speaker: "Speaker 1", text: "<|startoftranscript|> Hello there.<|2.00|>")
        XCTAssertEqual(SpeakerLabels.format([line]), "[00:01:12] Speaker 1: Hello there.")
    }

    func testFormatDropsEmptyLines() {
        let line = LabelledSegment(start: 1, end: 2, speaker: "You", text: "<|endoftext|>")
        XCTAssertEqual(SpeakerLabels.format([line]), "")
    }

    // MARK: Rename and merge

    private let transcript = """
        [00:00:01] You: Speaker 1: is what I'd call them.
        [00:00:05] Speaker 1: Hello.
        [00:00:09] Speaker 2: Hi.
        [00:00:12] Speaker 1: Bye.
        """

    func testRenameChangesLabelsAndNeverTheWords() {
        let out = SpeakerLabels.rename("Speaker 1", to: "Ana", in: transcript)
        XCTAssertEqual(
            out,
            """
            [00:00:01] You: Speaker 1: is what I'd call them.
            [00:00:05] Ana: Hello.
            [00:00:09] Speaker 2: Hi.
            [00:00:12] Ana: Bye.
            """)
    }

    func testRenamingToAnExistingNameMerges() {
        let out = SpeakerLabels.rename("Speaker 2", to: "Speaker 1", in: transcript)
        XCTAssertEqual(SpeakerLabels.speakers(in: out), ["You", "Speaker 1"])
    }

    func testRenameHandlesChineseWithoutShiftingText() {
        let text = "[00:00:01] Speaker 1: 市场部需要预算\n[00:00:02] Speaker 2: 好的"
        XCTAssertEqual(
            SpeakerLabels.rename("Speaker 2", to: "王", in: text),
            "[00:00:01] Speaker 1: 市场部需要预算\n[00:00:02] 王: 好的")
    }

    // MARK: Pipeline, with no real model

    private final class FakeTranscriber: SpeechTranscribing {
        var calls: [String] = []
        func transcribeSegments(path: String) async throws -> [Transcriber.Segment] {
            calls.append(path)
            let text = path.hasSuffix(".mic.wav") ? " from the mic" : " from the call"
            return [Transcriber.Segment(start: 0.5, end: 1.5, text: text)]
        }
    }

    private final class FakeDetector: SpeakerDetecting {
        var fail = false
        var paths: [String] = []
        func detectTurns(path: String) async throws -> [SpeakerTurn] {
            paths.append(path)
            if fail { throw CocoaError(.fileReadUnknown) }
            return [SpeakerTurn(start: 0, end: 2, speaker: 4)]
        }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func recording(name: String = "m.wav", seconds: Int = 2, mic: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
            let rate = 48_000
            for _ in 0..<seconds {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
                buffer.frameLength = AVAudioFrameCount(rate)
                let out = buffer.floatChannelData![0]
                let tone = (0..<rate).map { 0.3 * sin(Float($0) * 0.04) }
                for i in 0..<rate {
                    out[2 * i] = tone[i]
                    out[2 * i + 1] = tone[i]
                }
                if mic { tone.withUnsafeBufferPointer { writer.pushMic(mono: $0.baseAddress!, frameCount: rate) } }
                writer.pushSystem(buffer)
            }
        }
        return url
    }

    func testBothTracksGetTheirLabelsAndDetectionSeesOnlyTheSystemTrack() async throws {
        let detector = FakeDetector()
        let pipeline = RecordingPipeline(transcriber: FakeTranscriber(), detector: detector)
        let result = try await pipeline.transcribe(parts: [try recording()])
        XCTAssertEqual(result.segments.map(\.speaker), ["You", "Speaker 1"])
        XCTAssertEqual(detector.paths.count, 1)
        XCTAssertTrue(detector.paths[0].hasSuffix(".system.wav"))
        XCTAssertEqual(result.formatted, "[00:00:00] You: from the mic\n[00:00:00] Speaker 1: from the call")
    }

    func testMicOffMeansNoYouLabel() async throws {
        let pipeline = RecordingPipeline(transcriber: FakeTranscriber(), detector: FakeDetector())
        let result = try await pipeline.transcribe(parts: [try recording(mic: false)])
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1"])
    }

    func testDetectionFailureKeepsTheTranscriptAsYouAndOthers() async throws {
        let detector = FakeDetector()
        detector.fail = true
        let pipeline = RecordingPipeline(transcriber: FakeTranscriber(), detector: detector)
        let result = try await pipeline.transcribe(parts: [try recording()])
        XCTAssertEqual(result.segments.map(\.speaker), ["You", "Others"])
        XCTAssertEqual(result.notes.count, 1)
    }

    func testLaterPartsAreOffsetByRealLength() async throws {
        let pipeline = RecordingPipeline(transcriber: FakeTranscriber(), detector: FakeDetector())
        let parts = [try recording(name: "m.wav", seconds: 3), try recording(name: "m_part2.wav", seconds: 1)]
        let result = try await pipeline.transcribe(parts: parts)
        XCTAssertEqual(result.segments.map(\.start), [0.5, 0.5, 3.5, 3.5])
    }

    func testFinishWritesTheTranscriptArchivesAndMarksProcessed() async throws {
        let wav = try recording()
        let base = dir.appendingPathComponent("m")
        let pipeline = RecordingPipeline(transcriber: FakeTranscriber(), detector: FakeDetector())
        _ = try await RecordingPipeline.finish(parts: [wav], base: base, pipeline: pipeline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("m4a").path))
        let text = try String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("You: from the mic"))
        XCTAssertEqual(RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.state, .processed)
    }

    func testAFailedTranscriptionKeepsTheWAVAndTheRecordingStaysUnfinished() async throws {
        final class Failing: SpeechTranscribing {
            func transcribeSegments(path: String) async throws -> [Transcriber.Segment] {
                throw CocoaError(.fileReadUnknown)
            }
        }
        let wav = try recording()
        let base = dir.appendingPathComponent("m")
        try RecordingSidecar(createdAt: Date(), state: .recording).save(to: RecordingSidecar.url(forBase: base))
        do {
            _ = try await RecordingPipeline.finish(
                parts: [wav], base: base, pipeline: RecordingPipeline(transcriber: Failing(), detector: nil))
            XCTFail("the failure should surface")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertEqual(AudioRetention.unfinished(in: dir).map(\.lastPathComponent), ["m.wav"])
    }
}
