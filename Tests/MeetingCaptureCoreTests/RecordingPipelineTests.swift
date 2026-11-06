import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Recording to transcript and archive, with invented audio and no model.
final class RecordingPipelineTests: AudioTestCase {

    private let words = Transcriber.Segment(start: 0.5, end: 1, text: "invented words")

    private func pipeline(_ transcriber: SpeechTranscribing, detector: SpeakerDetecting? = nil) -> RecordingPipeline {
        RecordingPipeline(transcriber: transcriber, detector: detector)
    }

    private func finish(
        _ parts: [URL], base: String = "m", _ transcriber: SpeechTranscribing?, encoder: AudioEncoding = AACEncoder()
    ) async throws -> RecordingPipeline.Transcript? {
        try await RecordingPipeline.finish(
            parts: parts, base: url(base), pipeline: transcriber.map { pipeline($0) }, encoder: encoder, now: now)
    }

    private func wouldRetentionDelete() -> [String] {
        AudioRetention.clean(in: dir, days: 1, now: now.addingTimeInterval(400 * 86_400)).map(\.lastPathComponent)
    }

    // MARK: Timing (the code review's chunk-offset bug, on the live path)

    func testTrailingSilenceInAPartDoesNotShiftLaterTimestamps() async throws {
        // The first part is 3 s long, but its speech ends at 1 s.
        let parts = [try wav("m.wav", seconds: 3), try wav("m_part2.wav", seconds: 1)]
        let result = try await pipeline(ScriptedTranscriber(text: "x")).transcribe(parts: parts)
        XCTAssertEqual(result.segments.map(\.start), [0.5, 3.5])
        XCTAssertEqual(result.segments.map(\.end), [1, 4])
    }

    func testASilentPartStillAdvancesTime() async throws {
        let parts = [
            try wav("m.wav", seconds: 2, system: false), try wav("m_part2.wav", seconds: 1),
        ]
        let result = try await pipeline(ScriptedTranscriber(text: "x")).transcribe(parts: parts)
        XCTAssertEqual(result.segments.map(\.start), [2.5])
    }

    func testTranscriptStaysInTimeOrderAcrossPartsAndTracks() async throws {
        let transcriber = ScriptedTranscriber { path in
            path.hasSuffix(".mic.wav")
                ? [Transcriber.Segment(start: 0.2, end: 0.3, text: "mic")]
                : [
                    Transcriber.Segment(start: 0.1, end: 0.2, text: "a"),
                    Transcriber.Segment(start: 0.4, end: 0.5, text: "b"),
                ]
        }
        let parts = [try wav("m.wav", mic: true), try wav("m_part2.wav", mic: true)]
        let result = try await pipeline(transcriber).transcribe(parts: parts)
        let starts = result.segments.map(\.start)
        XCTAssertEqual(starts.count, 6)
        XCTAssertEqual(starts, starts.sorted())
    }

    // MARK: Speakers across parts

    func testRenamingAPartLabelJoinsItToTheFirstPart() async throws {
        let parts = [try wav("m.wav"), try wav("m_part2.wav")]
        let result = try await pipeline(ScriptedTranscriber(text: "x"), detector: ScriptedDetector())
            .transcribe(parts: parts)
        XCTAssertEqual(SpeakerLabels.speakers(in: result.formatted), ["Speaker 1", "Speaker 1 (part 2)"])

        let joined = SpeakerLabels.rename("Speaker 1 (part 2)", to: "Speaker 1", in: result.formatted)
        XCTAssertEqual(SpeakerLabels.speakers(in: joined), ["Speaker 1"])
        let renamed = SpeakerLabels.rename("Speaker 1", to: "Ana", in: joined)
        XCTAssertEqual(SpeakerLabels.speakers(in: renamed), ["Ana"])
    }

    func testRenamingTheFirstPartLeavesLaterPartsApart() async throws {
        let parts = [try wav("m.wav"), try wav("m_part2.wav")]
        let result = try await pipeline(ScriptedTranscriber(text: "x"), detector: ScriptedDetector())
            .transcribe(parts: parts)
        let renamed = SpeakerLabels.rename("Speaker 1", to: "Ana", in: result.formatted)
        XCTAssertEqual(SpeakerLabels.speakers(in: renamed), ["Ana", "Speaker 1 (part 2)"])
    }

    func testDetectionFailingInOnePartOnlyLabelsThatPartOthers() async throws {
        var calls = 0
        let detector = ScriptedDetector { _ in
            calls += 1
            if calls == 2 { throw CocoaError(.fileReadUnknown) }
            return [SpeakerTurn(start: 0, end: 100, speaker: 3)]
        }
        let parts = [try wav("m.wav"), try wav("m_part2.wav")]
        let result = try await pipeline(ScriptedTranscriber(text: "x"), detector: detector).transcribe(parts: parts)
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", "Others"])
        XCTAssertTrue(result.notes.contains { $0.contains("Speaker detection failed") }, "\(result.notes)")
    }

    func testNoDetectionMeansNoPartNote() async throws {
        let parts = [try wav("m.wav"), try wav("m_part2.wav")]
        let result = try await pipeline(ScriptedTranscriber(text: "x")).transcribe(parts: parts)
        XCTAssertEqual(result.segments.map(\.speaker), ["Others", "Others"])
        XCTAssertEqual(result.notes, [], "there are no part labels to explain")
    }

    // MARK: Temp copies of the audio

    func testSplitTracksDontOutliveTheRun() async throws {
        let transcriber = ScriptedTranscriber(text: "x")
        _ = try await pipeline(transcriber).transcribe(parts: [try wav("m.wav", mic: true)])
        XCTAssertEqual(transcriber.paths.count, 2)
        for path in transcriber.paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "a private copy stayed behind: \(path)")
        }
    }

    func testSplitTracksDontOutliveAFailure() async throws {
        let transcriber = ScriptedTranscriber { _ in throw CocoaError(.fileReadUnknown) }
        _ = try? await pipeline(transcriber).transcribe(parts: [try wav("m.wav")])
        XCTAssertEqual(transcriber.paths.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriber.paths[0]))
    }

    // MARK: Finishing: what may and may not arm retention

    func testASilenceMarkerTranscriptKeepsTheAudio() async throws {
        let original = try wav("m.wav")
        _ = try await finish([original], ScriptedTranscriber(text: "[BLANK_AUDIO]"))
        XCTAssertNil(loadSidecar("m")?.transcribedAt)
        XCTAssertEqual(wouldRetentionDelete(), [])
    }

    /// Deep review 4 and 5's neighbour: `[BLANK_AUDIO]` twice in one segment isn't "words" either.
    func testARepeatedSilenceMarkerIsStillNoWords() {
        for text in [
            "[BLANK_AUDIO] [BLANK_AUDIO]", "[BLANK_AUDIO][BLANK_AUDIO]", "(silence) (silence)", "[BLANK_AUDIO].",
        ] {
            XCTAssertTrue(SpeakerLabels.isSilenceMarker(text), text)
        }
    }

    func testSpecialTokensAloneAreNoWords() async throws {
        let original = try wav("m.wav")
        _ = try await finish([original], ScriptedTranscriber(text: "<|startoftranscript|><|endoftext|>"))
        XCTAssertNil(loadSidecar("m")?.transcribedAt)
    }

    /// Whisper labels noise like this. The transcript holds no speech, so the audio is
    /// still the only record, but retention treats it as transcribed.
    func testABracketedSoundOnlyTranscriptKeepsTheAudio() async throws {
        let original = try wav("m.wav")
        _ = try await finish([original], ScriptedTranscriber(text: "[Music]"))
        XCTExpectFailure(
            "BUG: unsure of the intent. A transcript of only [Music] counts as words, which arms retention on audio with no speech recorded in text."
        )
        XCTAssertNil(loadSidecar("m")?.transcribedAt, "no one said anything")
        XCTAssertEqual(wouldRetentionDelete(), [])
    }

    func testOneTrackWithWordsIsEnoughToArmRetention() async throws {
        let transcriber = ScriptedTranscriber { path in
            path.hasSuffix(".mic.wav") ? [] : [Transcriber.Segment(start: 0, end: 1, text: "invented")]
        }
        _ = try await finish([try wav("m.wav", mic: true)], transcriber)
        XCTAssertEqual(loadSidecar("m")?.transcribedAt, now)
    }

    func testAnEmptyWAVFinishesWithNothingArmedAndNothingLost() async throws {
        let empty = url("m.wav")
        try autoreleasepool { _ = try TrackWriter(outputURL: empty) }
        let transcriber = ScriptedTranscriber(text: "invented")
        _ = try await finish([empty], transcriber)
        XCTAssertEqual(transcriber.paths, [], "there's nothing to listen to")
        XCTAssertTrue(exists("m.wav"))
        XCTAssertNil(loadSidecar("m")?.transcribedAt)
        XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.wav"])
    }

    /// Missing the Screen Recording grant looks exactly like this.
    func testARecordingWithNoSoundAtAllTellsTheUser() async throws {
        let silent = try wav("m.wav", system: false)
        let result = try await pipeline(ScriptedTranscriber(text: "x")).transcribe(parts: [silent])
        XCTAssertEqual(result.segments, [])
        XCTAssertFalse(result.notes.isEmpty, "an empty transcript with no reason looks like a bug or a lost meeting")
    }

    func testNoiseOnEveryTrackKeepsTheAudioAndNames() async throws {
        let file = url("m.wav")
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(TestAudio.rate * 6)).map { _ in Float.random(in: -0.003...0.003, using: &generator) }
        try TestAudio.writeWAV(at: file, seconds: 6, mic: { noise[$0] }, system: { noise[$0] })
        let transcriber = ScriptedTranscriber(text: "invented")
        let result = try await finish([file], transcriber)
        XCTAssertEqual(transcriber.paths, [], "noise must never reach Whisper")
        XCTAssertEqual(result?.notes.count, 2)
        XCTAssertEqual(wouldRetentionDelete(), [])
    }

    // MARK: Finishing: failures

    func testAFailureOnALaterPartKeepsEverythingAndWritesNoTranscript() async throws {
        var calls = 0
        let transcriber = ScriptedTranscriber { [words] _ in
            calls += 1
            if calls == 2 { throw CocoaError(.fileReadUnknown) }
            return [words]
        }
        let parts = [try wav("m.wav"), try wav("m_part2.wav")]
        try saveSidecar("m", RecordingSidecar(createdAt: now, state: .recording))
        do {
            _ = try await finish(parts, transcriber)
            XCTFail("the failure must surface, or the audio would look finished")
        } catch {}
        XCTAssertEqual(try names(), ["m.mcmeta.json", "m.wav", "m_part2.wav"], "half a transcript must not be saved")
        XCTAssertEqual(loadSidecar("m")?.state, .recording)
    }

    func testACorruptPartStopsFinishingAndDeletesNothing() async throws {
        let good = try wav("m.wav")
        let bad = try touch("m_part2.wav", contents: Data(repeating: 7, count: 500))
        try saveSidecar("m", RecordingSidecar(createdAt: now, state: .recording))
        do {
            _ = try await finish([good, bad], ScriptedTranscriber(text: "x"))
            XCTFail("a part that can't be read must surface")
        } catch {}
        XCTAssertEqual(try names(), ["m.mcmeta.json", "m.wav", "m_part2.wav"])
        XCTAssertEqual(AudioRetention.unfinished(in: dir).map(\.lastPathComponent), ["m.wav"], "still offered")
    }

    func testAKeptWAVIsWhatRetentionListsAndTheTranscriptStillArrives() async throws {
        let result = try await finish([try wav("m.wav")], ScriptedTranscriber(text: "x"), encoder: FailingEncoder())
        XCTAssertEqual(result?.segments.count, 1)
        XCTAssertTrue(exists("m.txt"))
        XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.wav"])
    }

    /// A stop right after a rotation leaves an empty last part.
    func testAnEmptyLastPartDoesntStopARecordingFinishing() async throws {
        let first = try wav("m.wav")
        let last = url("m_part2.wav")
        try autoreleasepool { _ = try TrackWriter(outputURL: last) }
        let result = try await finish([first, last], ScriptedTranscriber(text: "x"))
        XCTAssertEqual(result?.segments.count, 1)
        XCTAssertEqual(loadSidecar("m")?.state, .processed)
        XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.m4a", "m_part2.wav"])
    }

    // MARK: Finishing: recovery after a crash

    func testRecoveryWithPartOneAlreadyEncodedTranscribesEveryPart() async throws {
        // A crash partway through archiving: part 1 is an M4A, part 2 is still a WAV.
        XCTAssertEqual(AudioArchive.archive(wav: try wav("m.wav", seconds: 2)), .archived(m4a: url("m.m4a")))
        try wav("m_part2.wav", seconds: 1)
        try saveSidecar("m", RecordingSidecar(createdAt: now, state: .recording))

        let parts = RecordingFiles.allParts(of: url("m.wav").path).map(URL.init(fileURLWithPath:))
        XCTAssertEqual(parts.map(\.lastPathComponent), ["m.m4a", "m_part2.wav"])
        let result = try await finish(parts, ScriptedTranscriber(text: "x"))

        XCTAssertEqual(result?.segments.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(result?.segments.last?.start), 2.5, accuracy: 0.2, "offset by part 1's real length")
        XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.m4a", "m_part2.m4a"])
        XCTAssertFalse(exists("m_part2.wav"))
    }

    func testRecoveryWithEveryPartEncodedStillFinishes() async throws {
        XCTAssertEqual(AudioArchive.archive(wav: try wav("m.wav")), .archived(m4a: url("m.m4a")))
        try saveSidecar("m", RecordingSidecar(createdAt: now, state: .recording))
        _ = try await finish([url("m.m4a")], ScriptedTranscriber(text: "x"))
        XCTAssertEqual(loadSidecar("m")?.state, .processed)
        XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.m4a"])
    }

    /// A crash after the M4A moved into place and before the WAV went. The transcript
    /// and sidecar then only know the WAV, so retention would leave the M4A forever.
    func testRecoveryWithBothCopiesOfAPartListsBothForRetention() async throws {
        let copy = try wav("copy.wav")
        XCTAssertEqual(AudioArchive.archive(wav: copy), .archived(m4a: url("copy.m4a")))
        try FileManager.default.moveItem(at: url("copy.m4a"), to: url("m.m4a"))
        try wav("m.wav")
        try saveSidecar("m", RecordingSidecar(createdAt: now, state: .recording))

        let parts = AudioRetention.unfinished(in: dir)
        XCTAssertEqual(parts.map(\.lastPathComponent), ["m.wav"])
        _ = try await finish(parts, ScriptedTranscriber(text: "x"))

        XCTExpectFailure(
            "BUG: after a crash leaving m.wav and m.m4a, the sidecar lists only m.wav, so the M4A outlives retention for good."
        )
        XCTAssertEqual(Set(loadSidecar("m")?.audioFiles ?? []), ["m.wav", "m.m4a"])
    }

    func testFinishingKeepsWhatTheSidecarAlreadyKnows() async throws {
        var value = RecordingSidecar(createdAt: now.addingTimeInterval(-5), state: .recording)
        value.speakerNames = ["Speaker 1": "Ana"]
        try saveSidecar("m", value)
        _ = try await finish([try wav("m.wav")], ScriptedTranscriber(text: "x"))
        XCTAssertEqual(loadSidecar("m")?.speakerNames, ["Speaker 1": "Ana"])
        XCTAssertEqual(loadSidecar("m")?.createdAt, now.addingTimeInterval(-5))
    }

    func testACorruptSidecarIsReplacedSoTheRecordingCanFinish() async throws {
        try Data("not json".utf8).write(to: url("m.mcmeta.json"))
        _ = try await finish([try wav("m.wav")], ScriptedTranscriber(text: "x"))
        XCTAssertEqual(loadSidecar("m")?.state, .processed)
    }

    // MARK: Known and not fixed

    /// KNOWN, NOT A NEW BUG: an external stereo file is read as `You` plus system audio.
    /// This records today's behaviour so a change gets noticed. It isn't what we want.
    func testKnownLimitAnExternalStereoFileIsReadAsYouAndOthers() async throws {
        let result = try await pipeline(ScriptedTranscriber(text: "x"))
            .transcribe(parts: [try wav("someone_elses.wav", seconds: 1, mic: true)])
        XCTAssertEqual(result.segments.map(\.speaker), ["You", "Others"])
    }

    // MARK: Splitting

    func testASteadyPartIsNoiseAndOneWithSpeechIsNot() {
        // Levels are per 100 ms now, and 50 of them (5 s) is the fewest that can be judged.
        let quiet = [Float](repeating: 0.002, count: AudioTracks.fewestWindows)
        XCTAssertTrue(AudioTracks.isSteadyQuietNoise(levels: quiet))
        var withSpeech = quiet
        withSpeech[20] = 0.3
        XCTAssertFalse(AudioTracks.isSteadyQuietNoise(levels: withSpeech), "one loud window means someone spoke")
    }

    func testPerfectSilenceIsNotCalledNoise() {
        XCTAssertFalse(
            AudioTracks.isSteadyQuietNoise(levels: [Float](repeating: 0, count: AudioTracks.fewestWindows)),
            "a silent track gets no 'quiet noise' note")
    }
}
