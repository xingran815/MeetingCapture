import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// M3.2 through `RecordingPipeline`: the mic is cleaned as a copy, echo-only lines are
/// dropped by timing and level, and no failure can cost the raw recording. Audio is
/// invented (see `EchoLab`), the transcriber is scripted, and there is no model.
final class EchoPipelineTests: AudioTestCase {

    private let rate = Double(EchoLab.rate)
    private let farWords = Transcriber.Segment(start: 6.0, end: 10.0, text: "words from the other side")
    /// A line with pauses in it, as Whisper makes them: a whole stretch of the far side's talk.
    private let farLine = Transcriber.Segment(start: 1.0, end: 5.0, text: "a long line from the other side")
    private let ownWords = Transcriber.Segment(start: 15.0, end: 20.0, text: "my own words")

    private struct Call {
        let mic: [Double]
        let system: [Double]
        let voice: [Double]
    }

    /// 24 s: the far side talks for the first 12 s and the room echoes it, then the user
    /// speaks from 14 s, with the system silent.
    private func call(seconds: Double = 24, farSeed: UInt64 = 11, voiceSeed: UInt64 = 77) -> Call {
        let far = EchoLab.speech(seconds: seconds, seed: farSeed, rms: 0.1)
        let system = EchoLab.only(far, seconds: 0...(seconds / 2))
        let voice = EchoLab.only(
            EchoLab.speech(seconds: seconds, seed: voiceSeed, rms: 0.1), seconds: (seconds / 2 + 2)...seconds)
        let mic = EchoLab.sum(
            EchoLab.sum(EchoLab.echo(of: system), voice), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        return Call(mic: mic, system: system, voice: voice)
    }

    private func scripted(
        mic micAnswer: [Transcriber.Segment], onMic: (([Double]) -> Void)? = nil
    ) -> ScriptedTranscriber {
        ScriptedTranscriber { path in
            if path.hasSuffix(".system.wav") { return [Transcriber.Segment(start: 0.5, end: 1, text: "system")] }
            onMic?((try? EchoLab.read(URL(fileURLWithPath: path))) ?? [])
            return micAnswer
        }
    }

    private func finish(
        _ parts: [URL], base: String = "m", _ transcriber: SpeechTranscribing, removeEcho: Bool = true,
        encoder: AudioEncoding = AACEncoder()
    ) async throws -> RecordingPipeline.Transcript? {
        var pipeline = RecordingPipeline(transcriber: transcriber, detector: nil)
        pipeline.removeEcho = removeEcho
        return try await RecordingPipeline.finish(
            parts: parts, base: url(base), pipeline: pipeline, encoder: encoder, now: now)
    }

    private func pipeline(_ transcriber: SpeechTranscribing, removeEcho: Bool = true) -> RecordingPipeline {
        var pipeline = RecordingPipeline(transcriber: transcriber, detector: nil)
        pipeline.removeEcho = removeEcho
        return pipeline
    }

    // MARK: The mic is cleaned, as a copy

    func testTheCleanedMicIsTranscribedAndEchoOnlyLinesAreLeftOut() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let before = try Data(contentsOf: url("m.wav"))
        var heard: [Double] = []
        let transcriber = scripted(mic: [farWords, ownWords]) { heard = $0 }

        let result = try await pipeline(transcriber).transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)

        let mine = result.segments.filter { $0.speaker == SpeakerLabels.you }
        XCTAssertEqual(mine.map(\.text), ["my own words"], "the line that was only echo should be gone")
        XCTAssertTrue(result.notes.contains { $0.contains("left out 1 mic line") }, "\(result.notes)")
        XCTAssertTrue(result.segments.contains { $0.text == "system" }, "the other side's track is untouched")

        // What the transcriber heard was the cleaned mic, not the raw one.
        let raw = try EchoLab.read(url("m.wav"), channel: 0)
        XCTAssertEqual(heard.count, raw.count)
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: raw, output: heard, from: 4, to: 11), 20)
        XCTAssertEqual(EchoLab.levelChangeDB(input: raw, output: heard, seconds: 15...23), 0, accuracy: 0.5)

        // The raw part is byte for byte what it was, and the clean copy sits beside it.
        XCTAssertEqual(try Data(contentsOf: url("m.wav")), before)
        XCTAssertEqual(result.cleanedAudio, [RecordingPipeline.cleanedURL(for: url("m.wav"))])
        XCTAssertTrue(exists("m_clean.wav"))
        XCTAssertEqual(try names(), ["m.wav", "m_clean.wav"])
    }

    /// Found by these tests: `looksLikeEcho` takes a line's "loudest fifth" by the CLEANED level.
    /// When the canceller works this well, the cleaned loud frames fall below the room (the
    /// residual gain takes the noise down with the echo), so the "loudest" cleaned frames are
    /// the pauses, where little was removed. The drop is then about 7 dB, under the 10 dB
    /// minimum, and a line made only of echo stays under `You`. Ranking by the mic's level
    /// instead would find the frames the echo was in.
    func testAnEchoLineWithPausesInItIsStillLeftOut() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [farLine, ownWords])).transcribe(parts: [url("m.wav")])
        XCTAssertEqual(
            result.segments.filter { $0.speaker == SpeakerLabels.you }.map(\.text), ["my own words"],
            "an echo-only line was kept as the user's")
    }

    /// The note can reach a log, so it gives a count and start times, never a line's words.
    /// From the M3.2 review, finding 8.
    func testTheNoteForLeftOutLinesHasTheCountAndStartTimesAndNoWords() async throws {
        let c = call(seconds: 140)  // the echo runs to 70 s
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let late = Transcriber.Segment(start: 65.0, end: 69.0, text: "secretphrase from the far end")
        let mine = Transcriber.Segment(start: 80.0, end: 85.0, text: "kept line")
        let result = try await pipeline(scripted(mic: [farLine, farWords, late, mine]))
            .transcribe(parts: [url("m.wav")])

        let note = try XCTUnwrap(result.notes.first { $0.contains("left out") }, "\(result.notes)")
        XCTAssertTrue(note.contains("left out 3 mic line(s) at 0:01, 0:06, 1:05"), note)
        XCTAssertTrue(note.hasPrefix("m.wav:"), note)
        for word in ["secretphrase", "other side", "far end", "long line", "kept line"] {
            XCTAssertFalse(
                result.notes.joined(separator: "\n").contains(word), "a line's words reached a note: \(word)")
        }
        XCTAssertEqual(
            result.segments.filter { $0.speaker == SpeakerLabels.you }.map(\.text), ["kept line"])
    }

    func testNoLinesLeftOutMeansNoNote() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [ownWords])).transcribe(parts: [url("m.wav")])
        XCTAssertFalse(result.notes.contains { $0.contains("left out") }, "\(result.notes)")
    }

    func testTheCleanCopyIsOnlyKeptWhenAsked() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [ownWords])).transcribe(parts: [url("m.wav")])
        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertEqual(try names(), ["m.wav"])
    }

    // MARK: 4. No echo, and the off switch

    func testNoEchoMeansTheRawMicIsTranscribedAndNoCopyIsMade() async throws {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let voice = EchoLab.speech(seconds: 24, seed: 77, rms: 0.1)  // headphones: no room
        try EchoLab.writeTwoTrack(mic: voice, system: far, to: url("m.wav"))
        let transcriber = scripted(mic: [farWords, ownWords])
        let result = try await pipeline(transcriber).transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)

        XCTAssertTrue(transcriber.paths.contains { $0.hasSuffix("m.mic.wav") }, "\(transcriber.paths)")
        XCTAssertEqual(transcriber.paths.count, 2, "one call for the mic and one for the system")
        XCTAssertEqual(result.segments.filter { $0.speaker == SpeakerLabels.you }.count, 2, "no line is judged")
        // From the M3.2 deep review, finding 3: no echo is said so, and nothing is said to have failed.
        XCTAssertEqual(result.notes.count, 1, "\(result.notes)")
        XCTAssertTrue(result.notes[0].contains("no echo showed up"), "\(result.notes)")
        XCTAssertFalse(result.notes.joined().contains("failed"), "\(result.notes)")
        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertEqual(try names(), ["m.wav"])
    }

    func testRemoveEchoOffLeavesTheMicAloneAndWritesNoCleanFile() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let transcriber = scripted(mic: [farWords, ownWords])
        let result = try await pipeline(transcriber, removeEcho: false)
            .transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)
        XCTAssertTrue(transcriber.paths.contains { $0.hasSuffix("m.mic.wav") }, "\(transcriber.paths)")
        XCTAssertEqual(result.segments.filter { $0.speaker == SpeakerLabels.you }.count, 2, "nothing is dropped")
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertEqual(try names(), ["m.wav"])

        _ = try await finish([url("m.wav")], scripted(mic: [ownWords]), removeEcho: false)
        XCTAssertEqual(try names(), ["m.m4a", "m.mcmeta.json", "m.txt"])
        XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.m4a"])
    }

    func testAMicOnlyOrSystemOnlyRecordingIsNotCleaned() async throws {
        try EchoLab.writeTwoTrack(
            mic: EchoLab.speech(seconds: 5, seed: 1, rms: 0.1), system: [], to: url("m.wav"))
        let transcriber = scripted(mic: [ownWords])
        let result = try await pipeline(transcriber).transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)
        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(try names(), ["m.wav"])
    }

    // MARK: 8. Failure can't lose audio

    /// A 44.1 kHz stereo file: the mic and system tracks split from it aren't 48 kHz, so
    /// the remover refuses them.
    private func wrongRateWAV(_ name: String) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url(name), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = 44_100 * 3
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<2 {
                let out = try XCTUnwrap(buffer.floatChannelData?[channel])
                for i in 0..<frames { out[i] = 0.2 * sin(Float(i) * (channel == 0 ? 0.05 : 0.03)) }
            }
            try file.write(from: buffer)
        }
    }

    func testIfTheRemoverCantRunTheRawMicIsTranscribedWithANote() async throws {
        try wrongRateWAV("m.wav")
        let transcriber = scripted(mic: [ownWords])
        let result = try await pipeline(transcriber).transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)
        XCTAssertTrue(transcriber.paths.contains { $0.hasSuffix("m.mic.wav") }, "\(transcriber.paths)")
        XCTAssertTrue(
            result.notes.contains { $0.contains("echo removal failed") && $0.contains("raw mic") }, "\(result.notes)")
        XCTAssertEqual(result.segments.filter { $0.speaker == SpeakerLabels.you }.map(\.text), ["my own words"])
        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertEqual(try names(), ["m.wav"])
    }

    func testAFailedRemoverStillArchivesTheRawPartAndArmsRetention() async throws {
        try wrongRateWAV("m.wav")
        _ = try await finish([url("m.wav")], scripted(mic: [ownWords]))
        XCTAssertEqual(try names(), ["m.m4a", "m.mcmeta.json", "m.txt"])
        let sidecar = try XCTUnwrap(loadSidecar("m"))
        XCTAssertEqual(sidecar.audioFiles, ["m.m4a"])
        XCTAssertEqual(sidecar.state, .processed)
        XCTAssertEqual(sidecar.transcribedAt, now, "the transcript has words, so the proof is unchanged")
    }

    /// Done-when 6: the M4A that replaces the WAV is made from the raw mic. The cleaned mic
    /// is a second file, so a way back always exists.
    func testTheArchivedM4AHoldsTheRawMicNotTheCleanedOne() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await finish([url("m.wav")], scripted(mic: [farWords, ownWords]))
        XCTAssertEqual(result?.cleanedAudio.count, 1)

        XCTAssertEqual(try names(), ["m.m4a", "m.mcmeta.json", "m.txt", "m_clean.m4a"])
        let sidecar = try XCTUnwrap(loadSidecar("m"))
        XCTAssertEqual(sidecar.audioFiles, ["m.m4a", "m_clean.m4a"])
        XCTAssertEqual(sidecar.transcribedAt, now)

        // Channel 1 of m.m4a is the raw mic: same loudness, frame by frame, echo included.
        let archived = try EchoLab.read(url("m.m4a"), channel: 0)
        let frame = 4_800
        let expected = EchoLab.framePower(c.mic, frame: frame)
        let got = EchoLab.framePower(archived, frame: frame)
        XCTAssertLessThanOrEqual(abs(got.count - expected.count), 1)
        let n = min(got.count, expected.count)
        XCTAssertGreaterThan(pearson(Array(got.prefix(n)), Array(expected.prefix(n))), 0.99)
        XCTAssertEqual(
            EchoLab.db(got.reduce(0, +) / expected.reduce(0, +)), 0, accuracy: 1.0, "the archive isn't the raw mic")
        let echoWindow = (2 * 48_000)..<(11 * 48_000)
        XCTAssertGreaterThan(
            EchoRemover.meanPower(Array(archived[echoWindow])), 0.001, "the echo is still in the archived mic")

        // The cleaned file is mono and quiet where the echo was.
        let cleaned = try EchoLab.read(url("m_clean.m4a"))
        XCTAssertLessThan(
            EchoRemover.meanPower(Array(cleaned[echoWindow])), EchoRemover.meanPower(Array(archived[echoWindow])) / 100)
    }

    private func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var ab = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            ab += (a[i] - ma) * (b[i] - mb)
            aa += (a[i] - ma) * (a[i] - ma)
            bb += (b[i] - mb) * (b[i] - mb)
        }
        return ab / max((aa * bb).squareRoot(), 1e-30)
    }

    /// Fails only for the cleaned copy, as a full disk might at the wrong moment.
    private struct CleanFailingEncoder: AudioEncoding {
        func encode(wav: URL, to m4a: URL) throws {
            if wav.lastPathComponent.contains("_clean") { throw CocoaError(.fileWriteOutOfSpace) }
            try AACEncoder().encode(wav: wav, to: m4a)
        }
    }

    func testACleanEncodeFailureLosesNothingAndStillArmsRetentionForTheRawPart() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await finish(
            [url("m.wav")], scripted(mic: [farWords, ownWords]), encoder: CleanFailingEncoder())
        XCTAssertNotNil(result)

        XCTAssertFalse(exists("m.wav"), "the raw part was proven and archived")
        XCTAssertTrue(exists("m.m4a"))
        XCTAssertTrue(exists("m_clean.wav"), "the clean copy that couldn't be encoded stays as it is")
        let sidecar = try XCTUnwrap(loadSidecar("m"))
        XCTAssertEqual(sidecar.transcribedAt, now, "a problem with the extra file must not block the raw part's proof")
        XCTAssertEqual(sidecar.audioFiles, ["m.m4a", "m_clean.wav"])
        XCTAssertTrue(exists("m.txt"))
    }

    func testARawEncodeFailureStillKeepsTheRawWAVAndDoesNotArmRetention() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        _ = try await finish([url("m.wav")], scripted(mic: [ownWords]), encoder: FailingEncoder())
        XCTAssertTrue(exists("m.wav"))
        XCTAssertNil(loadSidecar("m")?.transcribedAt)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: now.addingTimeInterval(400 * 86_400)), [])
        XCTAssertTrue(exists("m.wav"))
    }

    // MARK: 9. Names

    func testAnExistingFileAtTheCleanNameIsNeverOverwritten() async throws {
        for existing in ["m_clean.wav", "m_clean.m4a"] {
            let c = call()
            try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
            let theirs = Data("not audio, someone else's".utf8)
            try touch(existing, contents: theirs)

            let result = try await finish([url("m.wav")], scripted(mic: [farWords, ownWords]))

            XCTAssertEqual(try Data(contentsOf: url(existing)), theirs, "\(existing) was overwritten")
            XCTAssertEqual(result?.cleanedAudio, [], existing)
            XCTAssertEqual(loadSidecar("m")?.audioFiles, ["m.m4a"], "\(existing) isn't this recording's to delete")
            XCTAssertTrue(exists("m.m4a"))
            XCTAssertEqual(loadSidecar("m")?.transcribedAt, now)
            // Retention, much later, still leaves their file.
            AudioRetention.clean(in: dir, days: 1, now: now.addingTimeInterval(400 * 86_400))
            XCTAssertTrue(exists(existing), "retention took \(existing)")
            for name in try names() { try FileManager.default.removeItem(at: url(name)) }
        }
    }

    func testEachPartGetsItsOwnCleanFileAndNoneCountsAsAPart() async throws {
        let first = call(seconds: 12, farSeed: 41, voiceSeed: 42)
        let second = call(seconds: 12, farSeed: 43, voiceSeed: 44)
        try EchoLab.writeTwoTrack(mic: first.mic, system: first.system, to: url("m.wav"))
        try EchoLab.writeTwoTrack(mic: second.mic, system: second.system, to: url("m_part2.wav"))
        let parts = [url("m.wav"), url("m_part2.wav")]

        let result = try await pipeline(scripted(mic: [Transcriber.Segment(start: 8, end: 11, text: "me")]))
            .transcribe(parts: parts, keepingCleanedAudio: true)
        XCTAssertEqual(result.cleanedAudio.map(\.lastPathComponent), ["m_clean.wav", "m_part2_clean.wav"])
        XCTAssertEqual(RecordingFiles.allParts(of: url("m.wav").path), parts.map(\.path))
        XCTAssertEqual(RecordingFiles.allParts(of: url("m_part2.wav").path), parts.map(\.path))
        XCTAssertEqual(RecordingFiles.allParts(of: url("m_clean.wav").path), [url("m_clean.wav").path])
    }

    // MARK: From the M3.2 deep review

    /// Finding 4: the delay between the tracks jumped, so the note says some echo may remain.
    func testAStepInTheDelayMidPartLeavesANoteAndNoWords() async throws {
        let far = EchoLab.speech(seconds: 60, seed: 81, rms: 0.1)
        let tail = EchoLab.convolve(far, EchoLab.tail(seed: 99))
        let echo = EchoLab.sum(
            EchoLab.only(EchoLab.shifted(tail, by: 7_200), seconds: 0...30),
            EchoLab.only(EchoLab.shifted(tail, by: 10_200), seconds: 30...60))
        let mic = EchoLab.sum(echo, EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeTwoTrack(mic: mic, system: far, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [ownWords])).transcribe(parts: [url("m.wav")])
        let note = try XCTUnwrap(result.notes.first { $0.contains("moved") }, "\(result.notes)")
        XCTAssertTrue(note.hasPrefix("m.wav:"), note)
        XCTAssertFalse(result.notes.contains { $0.contains("no echo showed up") }, "\(result.notes)")
    }

    /// Finding 5: the start times of lines left out last past the terminal, in the sidecar,
    /// offset by the parts before. Never their words.
    func testLeftOutLineTimesSurviveInTheSidecar() async throws {
        let first = call(seconds: 12, farSeed: 41, voiceSeed: 42)
        let second = call(seconds: 12, farSeed: 43, voiceSeed: 44)
        try EchoLab.writeTwoTrack(mic: first.mic, system: first.system, to: url("m.wav"))
        try EchoLab.writeTwoTrack(mic: second.mic, system: second.system, to: url("m_part2.wav"))
        let echoLine = Transcriber.Segment(start: 1.0, end: 5.0, text: "uniqueechoword from the room")
        let mine = Transcriber.Segment(start: 8, end: 11, text: "uniquemineword")

        let result = try await finish([url("m.wav"), url("m_part2.wav")], scripted(mic: [echoLine, mine]))
        XCTAssertEqual(result?.leftOutLines, ["0:01", "0:13"], "\(result?.notes ?? [])")

        let sidecar = try XCTUnwrap(loadSidecar("m"))
        XCTAssertEqual(sidecar.leftOutLines, ["0:01", "0:13"])
        let json = try String(contentsOf: RecordingSidecar.url(forBase: url("m")), encoding: .utf8)
        XCTAssertTrue(json.contains("leftOutLines"))
        for word in ["uniqueechoword", "uniquemineword", "from the room"] {
            XCTAssertFalse(json.contains(word), "a line's words reached the sidecar: \(word)")
        }
    }

    func testASidecarWithoutLeftOutLinesStillLoadsAndNothingIsWrittenForIt() throws {
        let old = transcribed(ageDays: 3, files: ["m.m4a"])
        try saveSidecar("m", old)
        let text = try String(contentsOf: RecordingSidecar.url(forBase: url("m")), encoding: .utf8)
        XCTAssertFalse(text.contains("leftOutLines"), "an unset list should not be written")
        let loaded = try XCTUnwrap(loadSidecar("m"))
        XCTAssertNil(loaded.leftOutLines)
        XCTAssertEqual(loaded, old)
        // And a list round-trips.
        var withLines = old
        withLines.leftOutLines = ["0:07", "12:30"]
        try saveSidecar("n", withLines)
        XCTAssertEqual(loadSidecar("n"), withLines)
    }

    /// Finding 6: a clean copy used to be moved beside part 1 as soon as part 1 was done. If
    /// part 2 then threw, nothing listed it, and retention would never remove it.
    func testATranscriptionFailureOnALaterPartLeavesNoUnlistedCleanFile() async throws {
        let first = call(seconds: 12, farSeed: 41, voiceSeed: 42)
        let second = call(seconds: 12, farSeed: 43, voiceSeed: 44)
        try EchoLab.writeTwoTrack(mic: first.mic, system: first.system, to: url("m.wav"))
        try EchoLab.writeTwoTrack(mic: second.mic, system: second.system, to: url("m_part2.wav"))
        let parts = [url("m.wav"), url("m_part2.wav")]
        struct Boom: Error {}
        let failing = ScriptedTranscriber { path in
            if path.contains("part2") { throw Boom() }
            return [Transcriber.Segment(start: 8, end: 11, text: "me")]
        }

        do {
            _ = try await pipeline(failing).transcribe(parts: parts, keepingCleanedAudio: true)
            XCTFail("part 2 should have thrown")
        } catch is Boom {}
        XCTAssertEqual(try names(), ["m.wav", "m_part2.wav"], "a clean file was left beside the first part")

        // A later, successful attempt lists both.
        let result = try await finish(parts, scripted(mic: [Transcriber.Segment(start: 8, end: 11, text: "me")]))
        XCTAssertEqual(result?.cleanedAudio.map(\.lastPathComponent), ["m_clean.wav", "m_part2_clean.wav"])
        XCTAssertEqual(
            loadSidecar("m")?.audioFiles?.sorted(), ["m.m4a", "m_clean.m4a", "m_part2.m4a", "m_part2_clean.m4a"])
        XCTAssertEqual(
            try names().filter { $0.contains("_clean") }.sorted(), ["m_clean.m4a", "m_part2_clean.m4a"])
    }
}
