import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Slow pipeline cases: the left-out note, a delay step, sidecar times (D-77).
final class EchoPipelineSlowTests: EchoPipelineTestCase {

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
        XCTAssertFalse(result.notes.contains { $0.contains("no echo could be measured") }, "\(result.notes)")
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
}

/// Slow pipeline cases: failures that must not lose or leave files (D-77).
final class EchoPipelineFailureSlowTests: EchoPipelineTestCase {

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
}

/// Slow pipeline cases: the kept clean copy, no note, raw encode failure, pauses (D-77).
final class EchoPipelineKeepSlowTests: EchoPipelineTestCase {

    func testTheCleanCopyIsOnlyKeptWhenAsked() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [ownWords])).transcribe(parts: [url("m.wav")])
        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertEqual(try names(), ["m.wav"])
    }

    func testNoLinesLeftOutMeansNoNote() async throws {
        let c = call()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [ownWords])).transcribe(parts: [url("m.wav")])
        XCTAssertFalse(result.notes.contains { $0.contains("left out") }, "\(result.notes)")
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
}
