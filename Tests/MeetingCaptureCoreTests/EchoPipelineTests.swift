import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// M3.2 through `RecordingPipeline`: the mic is cleaned as a copy, echo-only lines are
/// dropped by timing and level, and no failure can cost the raw recording. Audio is
/// invented (see `EchoLab`), the transcriber is scripted, and there is no model.
final class EchoPipelineTests: EchoPipelineTestCase {


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

    /// From the M3.2 post-listen review: the normal path mixes in the temporary folder and
    /// moves the file into place, so the output folder holds only the part, the clean copy
    /// (two channels, listed) and nothing else, such as a stray UUID-named .wav.
    func testTheCleanCopyIsTwoChannelsListedAndLeavesNothingElseBehind() async throws {
        let c = call(seconds: 12)
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let result = try await pipeline(scripted(mic: [ownWords]))
            .transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)

        XCTAssertEqual(result.cleanedAudio, [url("m_clean.wav")])
        XCTAssertEqual(try AVAudioFile(forReading: url("m_clean.wav")).fileFormat.channelCount, 2)
        XCTAssertEqual(try names(), ["m.wav", "m_clean.wav"], "no stray temporary file in the output folder")
    }

    /// From the M3.2 post-listen review: when the clean copy can't be put in place, no
    /// `_clean` file is left (retention could never remove one, and a later run would skip the
    /// part because the name was taken), the list is empty, the transcript still succeeds,
    /// and a similarly named file of the user's survives. The move fails because the folder is
    /// read-only after the parts are written; the mix itself runs in the temporary folder.
    /// (A mix failing partway can't be reached without a seam; it ends in the same branch.)
    func testACleanCopyThatCantBeMovedIntoPlaceLeavesNothingAndKeepsUserFiles() async throws {
        let c = call(seconds: 12)
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let notes1 = Data("my notes".utf8)
        let notes2 = Data("my cleanup".utf8)
        try touch("m_clean_notes.wav", contents: notes1)
        try touch("m_cleanup.wav", contents: notes2)
        let before = try names()
        let raw = try Data(contentsOf: url("m.wav"))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "the folder is still writable (root?)")

        let result = try await pipeline(scripted(mic: [ownWords]))
            .transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)

        XCTAssertEqual(result.cleanedAudio, [])
        XCTAssertTrue(result.segments.contains { $0.speaker == SpeakerLabels.you && $0.text == "my own words" })
        XCTAssertTrue(result.segments.contains { $0.text == "system" })
        XCTAssertEqual(try names(), before, "nothing was added")
        XCTAssertFalse(exists("m_clean.wav"))
        XCTAssertFalse(exists("m_clean.m4a"))
        XCTAssertEqual(try Data(contentsOf: url("m_clean_notes.wav")), notes1)
        XCTAssertEqual(try Data(contentsOf: url("m_cleanup.wav")), notes2)
        XCTAssertEqual(try Data(contentsOf: url("m.wav")), raw)
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
        XCTAssertTrue(result.notes[0].contains("no echo could be measured"), "\(result.notes)")
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

        // The cleaned file is the recording's layout (user asked: the recording with echo removed):
        // two channels, mic quiet where the echo was, system track as recorded.
        XCTAssertEqual(try AVAudioFile(forReading: url("m_clean.m4a")).fileFormat.channelCount, 2)
        let cleaned = try EchoLab.read(url("m_clean.m4a"), channel: 0)
        XCTAssertLessThan(
            EchoRemover.meanPower(Array(cleaned[echoWindow])), EchoRemover.meanPower(Array(archived[echoWindow])) / 100)
        let cleanedSystem = try EchoLab.read(url("m_clean.m4a"), channel: 1)
        let archivedSystem = try EchoLab.read(url("m.m4a"), channel: 1)
        XCTAssertEqual(
            EchoLab.db(EchoRemover.meanPower(cleanedSystem) / EchoRemover.meanPower(archivedSystem)), 0, accuracy: 0.5,
            "the system track in the clean file is the recorded one")
        XCTAssertGreaterThan(EchoRemover.meanPower(cleanedSystem), 0.001)
    }

    /// From the M3.2 re-check: a far side that only speaks in 1 s bursts can't support a fit,
    /// so the remover has nothing to give but the raw mic. It says so, transcribes the raw
    /// mic, and leaves no clean file behind or in the sidecar's list.
    func testFarSideTooSparseForAFitSaysSoAndListsNoClean() async throws {
        let c = sparseCall()
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let transcriber = scripted(mic: [ownWords])
        let result = try await finish([url("m.wav")], transcriber)

        let notes = try XCTUnwrap(result?.notes)
        XCTAssertTrue(notes.contains { $0.contains("no echo could be measured") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("may include the other side") }, "\(notes)")
        XCTAssertFalse(notes.joined().contains("no echo showed up"), "\(notes)")
        XCTAssertFalse(notes.joined().contains("failed"), "\(notes)")
        XCTAssertTrue(transcriber.paths.contains { $0.hasSuffix("m.mic.wav") }, "\(transcriber.paths)")
        XCTAssertEqual(result?.cleanedAudio, [])
        XCTAssertEqual(result?.leftOutLines, [])
        let left = try names()
        XCTAssertFalse(left.contains { $0.contains("_clean") }, "\(left)")
        let listed = try XCTUnwrap(loadSidecar("m")?.audioFiles)
        XCTAssertFalse(listed.contains { $0.contains("_clean") }, "\(listed)")
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
}
