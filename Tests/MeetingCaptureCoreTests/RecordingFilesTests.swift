import XCTest

@testable import MeetingCaptureCore

/// Which files belong to a recording. Getting this wrong loses audio or a transcript.
final class RecordingFilesTests: AudioTestCase {

    private var caseInsensitiveDisk: Bool {
        try? touch("Probe.tmp")
        defer { try? FileManager.default.removeItem(at: url("Probe.tmp")) }
        return exists("PROBE.TMP")
    }

    func testPartsAreFoundForNamesWithDotsSpacesChineseAndBrackets() throws {
        for base in ["q3.review", "周会 (1)", "a+b[1]*", "team_part-time"] {
            let first = try touch("\(base).m4a").path
            let second = try touch("\(base)_part2.wav").path
            XCTAssertEqual(RecordingFiles.allParts(of: first), [first, second], base)
            XCTAssertEqual(RecordingFiles.allParts(of: second), [first, second], base)
        }
    }

    func testSimilarNamesAreNotParts() throws {
        let first = try touch("m.wav").path
        for other in [
            "m_part.wav", "m_part0.wav", "m_part1.wav", "m_part2x.wav", "m2.wav", "m_part2.txt", "xm_part2.wav",
        ] {
            try touch(other)
        }
        XCTAssertEqual(RecordingFiles.allParts(of: first), [first])
    }

    func testUppercaseExtensionsCount() throws {
        let first = try touch("m.WAV").path
        let second = try touch("m_part2.M4A").path
        XCTAssertEqual(RecordingFiles.allParts(of: first), [first, second])
    }

    func testAMissingFileComesBackAsItselfSoCallersCanTell() {
        let path = url("gone.wav").path
        XCTAssertEqual(RecordingFiles.allParts(of: path), [path])
    }

    /// `--transcribe-only talk_part1.wav`: the file asked for has to be in the answer.
    func testTheFileAskedForIsAlwaysAmongItsParts() throws {
        let first = try touch("talk_part1.wav").path
        let second = try touch("talk_part2.wav").path
        XCTAssertEqual(RecordingFiles.allParts(of: first), [first, second])
        XCTAssertEqual(RecordingFiles.allParts(of: second), [first, second])
    }

    func testBaseNameOnlyStripsAPartSuffixAtTheEnd() {
        XCTAssertEqual(RecordingFiles.baseName(of: "m_part12"), "m")
        XCTAssertEqual(RecordingFiles.baseName(of: "m_part2_final"), "m_part2_final")
        XCTAssertEqual(RecordingFiles.baseName(of: "m_part"), "m_part")
    }

    // MARK: Refusing a name

    func testConflictSeesUppercaseExtensions() throws {
        try touch("m.M4A")
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: url("m")))
    }

    func testConflictIgnoresAnotherRecordingThatSharesAPrefix() throws {
        try touch("m2.wav")
        try touch("m_notes.txt")
        XCTAssertNil(RecordingFiles.conflict(forNewRecordingAt: url("m")))
    }

    func testANameWithDotsIsStillProtected() throws {
        try touch("q3.review.m4a")
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: url("q3.review")))
    }

    /// Deep review 8's neighbour: APFS calls these one file by default, so a recording
    /// to `Standup.wav` would truncate the existing `standup.wav`.
    func testAnExistingNameInAnotherCaseIsRefusedOnACaseInsensitiveDisk() throws {
        try XCTSkipUnless(caseInsensitiveDisk, "this disk tells the two names apart")
        try touch("standup.wav")
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: url("Standup")), "the WAV would be overwritten")
        try FileManager.default.removeItem(at: url("standup.wav"))
        try touch("standup.txt")
        XCTAssertNotNil(
            RecordingFiles.conflict(forNewRecordingAt: url("Standup")), "the transcript would be overwritten")
    }

    /// A part written as `talk_part1` in another case is the same file on the default disk.
    func testAPartNamedInAnotherCaseIsRefusedOnACaseInsensitiveDisk() throws {
        try XCTSkipUnless(caseInsensitiveDisk, "this disk tells the two names apart")
        try touch("TALK_PART1.WAV")
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: url("talk")))
        try FileManager.default.removeItem(at: url("TALK_PART1.WAV"))
        try touch("Talk_Part2.m4a")
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: url("talk")), "a later part counts too")
    }

    // MARK: Length

    func testDurationIsNilForAnythingThatIsntAudio() throws {
        XCTAssertNil(RecordingFiles.duration(ofAudioAt: url("gone.wav").path))
        XCTAssertNil(RecordingFiles.duration(ofAudioAt: try touch("empty.wav").path))
        XCTAssertNil(
            RecordingFiles.duration(ofAudioAt: try touch("junk.m4a", contents: Data(repeating: 7, count: 64)).path))
    }
}
