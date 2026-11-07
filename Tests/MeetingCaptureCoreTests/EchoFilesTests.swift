import XCTest

@testable import MeetingCaptureCore

/// The `_clean` copy of a mic is part of its recording: listed in the sidecar, deleted with it,
/// and never mistaken for a part, or for another recording's file (D-44).
final class EchoFilesTests: AudioTestCase {

    private func laterNow() -> Date { now.addingTimeInterval(400 * 86_400) }

    func testTheCleanNameIsTheRawNameWithCleanBeforeTheExtension() {
        XCTAssertEqual(RecordingPipeline.cleanedURL(for: url("meeting.wav")), url("meeting_clean.wav"))
        XCTAssertEqual(RecordingPipeline.cleanedURL(for: url("meeting_part2.wav")), url("meeting_part2_clean.wav"))
        XCTAssertEqual(RecordingPipeline.cleanedURL(for: url("a b.c.wav")), url("a b.c_clean.wav"))
    }

    func testCleanFilesAreNotPartsOfTheRecording() throws {
        for name in [
            "meeting.wav", "meeting_part2.wav", "meeting_clean.wav", "meeting_part2_clean.wav", "meeting_clean.m4a",
        ] {
            try touch(name)
        }
        let parts = [url("meeting.wav").path, url("meeting_part2.wav").path]
        XCTAssertEqual(RecordingFiles.allParts(of: url("meeting.wav").path), parts)
        XCTAssertEqual(RecordingFiles.allParts(of: url("meeting_part2.wav").path), parts)
        // Asked for by name, a clean file is just itself.
        XCTAssertEqual(RecordingFiles.allParts(of: url("meeting_clean.wav").path), [url("meeting_clean.wav").path])
        XCTAssertEqual(
            RecordingFiles.allParts(of: url("meeting_part2_clean.wav").path), [url("meeting_part2_clean.wav").path])
    }

    /// Spec M3.2 and D-44: the clean M4A is listed in `audioFiles`, so it goes with the
    /// recording. This is what the pipeline writes, so it should be deleted.
    func testRetentionDeletesTheCleanM4AListedInTheSidecar() throws {
        for name in ["meeting.m4a", "meeting_clean.m4a", "meeting.txt"] { try touch(name) }
        try saveSidecar("meeting", transcribed(ageDays: 400, files: ["meeting.m4a", "meeting_clean.m4a"]))
        let deleted = AudioRetention.clean(in: dir, days: 1, now: now).map(\.lastPathComponent)
        XCTAssertEqual(deleted, ["meeting.m4a", "meeting_clean.m4a"])
        XCTAssertEqual(try names(), ["meeting.mcmeta.json", "meeting.txt"])
    }

    func testRetentionDeletesTheCleanFilesOfLaterPartsToo() throws {
        for name in ["meeting.m4a", "meeting_clean.m4a", "meeting_part2.m4a", "meeting_part2_clean.m4a"] {
            try touch(name)
        }
        try saveSidecar(
            "meeting",
            transcribed(
                ageDays: 400,
                files: ["meeting.m4a", "meeting_part2.m4a", "meeting_clean.m4a", "meeting_part2_clean.m4a"]))
        let deleted = AudioRetention.clean(in: dir, days: 1, now: now).map(\.lastPathComponent)
        XCTAssertEqual(deleted, ["meeting.m4a", "meeting_clean.m4a", "meeting_part2.m4a", "meeting_part2_clean.m4a"])
    }

    func testLookAlikesOfACleanFileSurviveRetention() throws {
        for name in [
            "meeting.m4a", "meeting_clean.m4a", "meeting_clean_notes.m4a", "meeting_clean.wav", "meeting_cleaned.m4a",
            "other_clean.m4a", "other.m4a", "xmeeting_clean.m4a",
        ] {
            try touch(name)
        }
        try saveSidecar("meeting", transcribed(ageDays: 400, files: ["meeting.m4a", "meeting_clean.m4a"]))
        // Another recording, also old, that lists only its own files.
        try saveSidecar("other", transcribed(ageDays: 400, files: ["other.m4a"]))
        AudioRetention.clean(in: dir, days: 1, now: now)
        for survivor in [
            "meeting_clean_notes.m4a", "meeting_clean.wav", "meeting_cleaned.m4a", "other_clean.m4a",
            "xmeeting_clean.m4a",
        ] {
            XCTAssertTrue(exists(survivor), "\(survivor) was deleted but isn't listed")
        }
        XCTAssertFalse(exists("other.m4a"))
    }

    func testASidecarCantClaimAnotherRecordingsCleanFile() throws {
        for name in ["meeting.m4a", "other.m4a", "other_clean.m4a"] { try touch(name) }
        try saveSidecar("other", transcribed(ageDays: 400, files: ["other.m4a"]))
        // A damaged or planted sidecar for `meeting` that names the other recording's files.
        try saveSidecar("meeting", transcribed(ageDays: 400, files: ["meeting.m4a", "other_clean.m4a", "other.m4a"]))
        let deleted = AudioRetention.clean(in: dir, days: 1, now: now).map(\.lastPathComponent)
        XCTAssertEqual(deleted, ["meeting.m4a", "other.m4a"], "only each recording's own, listed files go")
        XCTAssertTrue(exists("other_clean.m4a"))
    }

    func testACleanFileIsNotDeletedBeforeTheRawPartIsProven() throws {
        // No transcribedAt: the clean copy is not a way to make the audio eligible.
        for name in ["meeting.wav", "meeting_clean.m4a"] { try touch(name) }
        try saveSidecar(
            "meeting",
            RecordingSidecar(
                createdAt: now.addingTimeInterval(-400 * 86_400), state: .processed,
                audioFiles: ["meeting.wav", "meeting_clean.m4a"]))
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: now), [])
    }

    func testAKeptCleanWAVIsListedSoAudioCleanupDoesNotOfferIt() throws {
        for name in ["meeting.m4a", "meeting_clean.wav", "stray_clean.wav"] { try touch(name) }
        try saveSidecar("meeting", transcribed(ageDays: 1, files: ["meeting.m4a", "meeting_clean.wav"]))
        XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir).map(\.lastPathComponent), ["stray_clean.wav"])
    }

    func testANewRecordingCantTakeTheNameOfAnExistingCleanFile() throws {
        try touch("meeting_clean.wav")
        XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: url("meeting_clean")))
    }
}
