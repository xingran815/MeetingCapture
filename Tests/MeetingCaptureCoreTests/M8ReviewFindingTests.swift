import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// M8's deep and security review findings (commit b2aac1e), each named after its finding.
/// The debug pair `<part>_mic_before.wav` / `<part>_mic_after.wav` must belong to its recording
/// for retention and Move to Trash, and must never claim a file that was already there.
final class M8DebugPairFilesTests: EchoPipelineTestCase {

    private func audioFiles(_ base: String = "m") -> [String] { loadSidecar(base)?.audioFiles ?? [] }

    private func debugPipeline(_ transcriber: SpeechTranscribing, keep: Bool) -> RecordingPipeline {
        var p = pipeline(transcriber)
        p.keepEchoDebugAudio = keep
        return p
    }

    private func finishKeeping(_ keep: Bool) async throws -> RecordingPipeline.Transcript? {
        try await RecordingPipeline.finish(
            parts: [url("m.wav")], base: url("m"), pipeline: debugPipeline(scripted(mic: [ownWords]), keep: keep),
            encoder: AACEncoder(), now: now)
    }

    // MARK: Deep review must-fix 1: ownerBase

    func testDeepReviewMustFix_ownerBaseCountsTheDebugPair() {
        XCTAssertEqual(RecordingFiles.ownerBase(of: "meeting_part2_mic_after"), "meeting")
        XCTAssertEqual(RecordingFiles.ownerBase(of: "meeting_mic_before"), "meeting")
        XCTAssertEqual(RecordingFiles.ownerBase(of: "x_mic_before"), "x")
        XCTAssertEqual(RecordingFiles.ownerBase(of: "meeting_part2_clean"), "meeting")
        XCTAssertEqual(RecordingFiles.ownerBase(of: "meeting_mic_after_notes"), "meeting_mic_after_notes")
        XCTAssertEqual(RecordingFiles.ownerBase(of: "mic_before"), "mic_before", "a bare ending has no owner")
        XCTAssertEqual(RecordingFiles.ownerBase(of: "mic_after"), "mic_after")
    }

    // MARK: Deep review must-fix 2: retention

    func testDeepReviewMustFix_retentionDeletesTheListedDebugPairAndSimilarNamesSurvive() throws {
        for name in ["meeting.m4a", "meeting_mic_before.wav", "meeting_mic_after.wav", "meeting.txt"] {
            try touch(name)
        }
        try touch("meeting_mic_before_notes.wav", contents: Data("mine".utf8))
        try touch("meeting_mic_after_notes.wav", contents: Data("mine".utf8))
        try saveSidecar(
            "meeting",
            transcribed(
                ageDays: 40, files: ["meeting.m4a", "meeting_mic_before.wav", "meeting_mic_after.wav"]))
        let deleted = AudioRetention.clean(in: dir, days: 30, now: now).map(\.lastPathComponent)
        XCTAssertEqual(Set(deleted), ["meeting.m4a", "meeting_mic_before.wav", "meeting_mic_after.wav"])
        XCTAssertTrue(exists("meeting_mic_before_notes.wav"), "a similarly named file survives")
        XCTAssertTrue(exists("meeting_mic_after_notes.wav"))
        XCTAssertTrue(exists("meeting.txt"))
    }

    func testDeepReviewMustFix_aDebugNamedFileWithItsOwnSidecarIsNotTakenByAnotherRecording() throws {
        try touch("meeting.m4a")
        try touch("meeting_mic_before.wav", contents: Data("someone else's".utf8))
        try saveSidecar("meeting", transcribed(ageDays: 40, files: ["meeting.m4a", "meeting_mic_before.wav"]))
        try saveSidecar("meeting_mic_before", transcribed(ageDays: 1, files: ["meeting_mic_before.wav"]))
        _ = AudioRetention.clean(in: dir, days: 30, now: now)
        XCTAssertFalse(exists("meeting.m4a"))
        XCTAssertTrue(exists("meeting_mic_before.wav"), "it has a sidecar of its own, so it isn't meeting's to delete")
    }

    // MARK: Deep review must-fix 3: the pipeline makes the pair

    func testDeepReviewMustFix_theFlagKeepsMonoDebugCopiesOfThePartListedInTheSidecar() async throws {
        let c = call(seconds: 12)
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let partLength = try AVAudioFile(forReading: url("m.wav")).length
        let result = try await finishKeeping(true)

        XCTAssertEqual(
            result?.echoDebugAudio.map(\.lastPathComponent).sorted(), ["m_mic_after.wav", "m_mic_before.wav"])
        for name in ["m_mic_before.wav", "m_mic_after.wav"] {
            XCTAssertTrue(exists(name), name)
            let file = try AVAudioFile(forReading: url(name))
            XCTAssertEqual(file.fileFormat.channelCount, 1, "\(name) is mono")
            XCTAssertEqual(file.length, partLength, "\(name) has the part's length")
            XCTAssertTrue(audioFiles().contains(name), "\(name) is listed: \(audioFiles())")
        }
        let raw = try EchoLab.read(url("m_mic_before.wav"))
        let after = try EchoLab.read(url("m_mic_after.wav"))
        XCTAssertNotEqual(raw, after, "the after copy is the cleaned mic")
    }

    func testDeepReviewMustFix_withTheFlagOffNoDebugCopiesAreMade() async throws {
        let c = call(seconds: 12)
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        _ = try await finishKeeping(false)
        XCTAssertFalse(exists("m_mic_before.wav"))
        XCTAssertFalse(exists("m_mic_after.wav"))
        XCTAssertFalse(audioFiles().contains { $0.contains("_mic_") }, "\(audioFiles())")
    }

    // MARK: Deep review must-fix 4: a name already taken

    func testDeepReviewMustFix_aTakenDebugNameStaysByteIdenticalUnlistedWithANote() async throws {
        let c = call(seconds: 12)
        try EchoLab.writeTwoTrack(mic: c.mic, system: c.system, to: url("m.wav"))
        let theirs = Data("an earlier run's copy, or someone's file".utf8)
        try touch("m_mic_before.wav", contents: theirs)
        let result = try await finishKeeping(true)

        XCTAssertEqual(try Data(contentsOf: url("m_mic_before.wav")), theirs)
        XCTAssertFalse(audioFiles().contains("m_mic_before.wav"), "not claimed: \(audioFiles())")
        XCTAssertEqual(result?.echoDebugAudio.map(\.lastPathComponent), ["m_mic_after.wav"])
        XCTAssertTrue(audioFiles().contains("m_mic_after.wav"), "the free name is still kept")
        XCTAssertTrue(
            result?.notes.contains { $0.contains("m_mic_before.wav") && $0.contains("left as it is") } == true,
            "\(result?.notes ?? [])")
        XCTAssertEqual(try names().filter { $0.hasSuffix(".wav") && $0.contains("-") }, [], "no scratch copy left")
    }
}

/// Deep review must-fix 2, through Move to Trash.
final class M8DebugPairTrashTests: NotebookTestCase {

    func testDeepReviewMustFix_trashPlanTakesTheListedDebugPairAndLeavesSimilarNames() throws {
        try makeRecording()
        for n in [recName + ".m4a", recName + "_mic_before.wav", recName + "_mic_after.wav"] {
            try touch(n, contents: Data("x".utf8))
        }
        try touch(recName + "_mic_before_notes.wav", contents: Data("mine".utf8))
        try touch(recName + "_mic_after.txt", contents: Data("mine".utf8))
        try saveSidecar(
            recName,
            RecordingSidecar(
                createdAt: now, state: .processed, transcribedAt: now,
                audioFiles: [recName + ".m4a", recName + "_mic_before.wav", recName + "_mic_after.wav"]))
        let plan = Set(try Notebook.trashPlan(base: base).files.map(\.lastPathComponent))
        XCTAssertTrue(plan.contains(recName + "_mic_before.wav"), "\(plan)")
        XCTAssertTrue(plan.contains(recName + "_mic_after.wav"), "\(plan)")
        XCTAssertFalse(plan.contains(recName + "_mic_before_notes.wav"))
        XCTAssertFalse(plan.contains(recName + "_mic_after.txt"))
    }

    func testDeepReviewMustFix_aDebugNamedFileWithItsOwnSidecarIsNotTrashedWithAnotherRecording() throws {
        try makeRecording()
        try touch(recName + ".m4a", contents: Data("x".utf8))
        try touch(recName + "_mic_before.wav", contents: Data("theirs".utf8))
        try saveSidecar(
            recName,
            RecordingSidecar(
                createdAt: now, state: .processed, transcribedAt: now,
                audioFiles: [recName + ".m4a", recName + "_mic_before.wav"]))
        try saveSidecar(
            recName + "_mic_before",
            RecordingSidecar(
                createdAt: now, state: .processed, transcribedAt: now, audioFiles: [recName + "_mic_before.wav"]))
        let plan = Set(try Notebook.trashPlan(base: base).files.map(\.lastPathComponent))
        XCTAssertTrue(plan.contains(recName + ".m4a"))
        XCTAssertFalse(plan.contains(recName + "_mic_before.wav"), "\(plan)")
    }
}

/// Security review L2.
final class M8NewRecordingNameTests: AudioTestCase {

    func testSecurityReviewL2_aNewRecordingCantBeNamedLikeADerivedFile() {
        for stem in ["standup_mic_after", "x_mic_before", "y_clean"] {
            let why = RecordingFiles.conflict(forNewRecordingAt: url(stem))
            XCTAssertNotNil(why, stem)
            XCTAssertTrue(why?.contains("kept for files made from a recording") == true, "\(why ?? "")")
        }
    }

    func testSecurityReviewL2_otherNamesStillWork() {
        for stem in ["mic_after", "mic_before", "clean", "standup_mic_after_2", "standup_mic_after_notes", "standup"] {
            XCTAssertNil(RecordingFiles.conflict(forNewRecordingAt: url(stem)), stem)
        }
    }
}

/// Deep review should-fix: the linear stage on disk, and the weights decode.
final class M8LinearStageDiskSerialTests: XCTestCase {

    private func stageFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("meetingcapture-echo-") })
    }

    func testDeepReviewShouldFix_theFileHoldsFourBytesPerFrameAndReadsBackQuantized() throws {
        let n = 5000
        let stage = try LinearStageFile(frames: n, available: nil)
        defer { stage.remove() }
        let error = EchoLab.speech(frames: n, seed: 3, rms: 0.05)
        let estimate = EchoLab.speech(frames: n, seed: 4, rms: 0.02)
        try stage.append(error: Array(error[0..<2000]), estimate: Array(estimate[0..<2000]))
        try stage.append(error: Array(error[2000...]), estimate: Array(estimate[2000...]))
        XCTAssertEqual(stage.frames, n)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: stage.url.path)[.size] as? NSNumber)
        XCTAssertEqual(size.intValue, 4 * n, "two int16 per frame")

        let codes = try Data(contentsOf: stage.url).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(codes.count, 2 * n)
        for i in stride(from: 0, to: n, by: 97) {
            XCTAssertEqual(codes[2 * i], LinearStageFile.code(error[i]), "error \(i)")
            XCTAssertEqual(codes[2 * i + 1], LinearStageFile.code(estimate[i]), "estimate \(i)")
            XCTAssertEqual(Double(codes[2 * i]) / 32768, error[i], accuracy: 1.0 / 32768)
        }
    }

    func testDeepReviewShouldFix_spectraReadBackMatchTheQuantizedSignal() throws {
        let n = 4096
        let tone = (0..<n).map { 0.2 * sin(Double($0) * 0.3) }
        let stage = try LinearStageFile(frames: n, available: nil)
        defer { stage.remove() }
        try stage.append(error: tone, estimate: [Double](repeating: 0, count: n))
        var peak = 0.0
        var estimatePeak = 0.0
        try stage.forEachFrame { e, d in
            peak = max(peak, e.max() ?? 0)
            estimatePeak = max(estimatePeak, d.max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 1e-3, "the tone is there")
        XCTAssertEqual(estimatePeak, 0, "a zero estimate reads back as zero")
    }

    func testDeepReviewShouldFix_tooLittleFreeSpaceThrowsBeforeWritingAnything() throws {
        let frames = 1000
        let before = stageFiles()
        let need = Int64(frames) * 4 + LinearStageFile.spareBytes
        XCTAssertThrowsError(try LinearStageFile(frames: frames, available: need - 1)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
            XCTAssertTrue(error.localizedDescription.contains("not enough free disk space"), "\(error)")
        }
        XCTAssertThrowsError(try LinearStageFile(frames: frames, available: 0))
        XCTAssertEqual(stageFiles(), before, "no temp file left behind")

        let ok = try LinearStageFile(frames: frames, available: need)
        ok.remove()
        let unknown = try LinearStageFile(frames: frames, available: nil)
        unknown.remove()
        XCTAssertEqual(stageFiles(), before)
    }

    /// `EchoRemover.clean` has no seam for free space, so the pipeline's note for a throw is
    /// covered by `EchoPipelineTests.testIfTheRemoverCantRunTheRawMicIsTranscribedWithANote`
    /// (the same catch); here only the throw's message is checked to be fit for that note.
    func testDeepReviewShouldFix_theOutOfSpaceMessageNamesTheCause() {
        XCTAssertThrowsError(try LinearStageFile(frames: 10, available: 5_000_000)) { error in
            XCTAssertTrue(error.localizedDescription.contains("5 MB free"), "\(error.localizedDescription)")
        }
    }

    // MARK: Deep review low: the weights decode

    /// `NeuralMask.weights` is private, so the shipped base64 is decoded here as half floats:
    /// not all zero, all finite (a failed vImage conversion leaves zeros or garbage).
    func testDeepReviewLow_theShippedWeightsAreFiniteAndNotAllZero() throws {
        let text = EchoSuppressorWeights.base64.filter { !$0.isWhitespace }
        let data = try XCTUnwrap(Data(base64Encoded: text))
        let halves = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        XCTAssertEqual(halves.count, EchoSuppressorWeights.count)
        XCTAssertTrue(halves.allSatisfy { $0.isFinite }, "every weight is finite")
        XCTAssertGreaterThan(halves.filter { $0 != 0 }.count, halves.count / 2, "most weights are non-zero")
        // And the network built from them gives a live, finite answer that isn't a constant zero.
        var network = NeuralMask()
        let bins = EchoSuppressorWeights.bins
        let loud = [Double](repeating: 1e-2, count: bins)
        let quiet = [Double](repeating: 1e-10, count: bins)
        let mask = network.mask(errorPower: loud, estimatePower: quiet)
        XCTAssertTrue(mask.allSatisfy { $0.isFinite })
        XCTAssertTrue(mask.contains { $0 > 0 }, "a decoded network doesn't answer all zeros")
    }
}
