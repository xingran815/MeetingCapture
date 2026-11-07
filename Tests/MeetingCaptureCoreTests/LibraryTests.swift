import XCTest

@testable import MeetingCaptureCore

/// The library list, the report page, speaker rename and retention, on invented files in
/// a temp folder. Every test builds its own folder (AudioTestCase).
final class LibraryTests: AudioTestCase {

    private let transcript =
        "[00:00:01] You: hello there\n[00:00:05] Speaker 1: hi, the plan: ship\n[00:00:09] Speaker 2: ok\n"

    private func report(topic: String) -> Report {
        Report(
            topic: topic, scenario: "meeting", scenarioTitle: "Company meeting", createdAt: "2026-11-07T12:48:00Z",
            durationSeconds: 125, language: "en", models: .init(), reviewed: true, notices: [],
            sections: [
                Report.Section(
                    id: "summary", title: "Summary", kind: .prose, note: nil,
                    items: [Report.Item(text: "We agreed to ship.")])
            ],
            reviewChanges: [], transcript: [TranscriptEntry(start: 1, end: 2, speaker: "You", text: "hello there")])
    }

    private func writeReport(_ base: String, topic: String) throws {
        try JSONEncoder().encode(report(topic: topic)).write(to: url(base + ".report.json"))
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: url(name), atomically: true, encoding: .utf8)
    }

    private func entry(_ base: String) throws -> LibraryEntry {
        try XCTUnwrap(Library.entries(in: dir).first { $0.base.lastPathComponent == base }, base)
    }

    // MARK: entries

    func testEmptyOrMissingFolderGivesNoEntries() {
        XCTAssertEqual(Library.entries(in: dir), [])
        XCTAssertEqual(Library.entries(in: url("nope")), [])
    }

    func testEntriesAreNewestFirstAndFlagsFollowTheFiles() throws {
        // Oldest: audio only. Middle: transcript and report. Newest: unfinished.
        try saveSidecar("meeting_old", transcribed(ageDays: 10, files: ["meeting_old.m4a"]))
        try touch("meeting_old.m4a")
        try saveSidecar("meeting_mid", transcribed(ageDays: 5, files: ["meeting_mid.m4a"]))
        try touch("meeting_mid.m4a")
        try write("meeting_mid.txt", transcript)
        try writeReport("meeting_mid", topic: "Budget")
        try saveSidecar(
            "meeting_new", RecordingSidecar(createdAt: now.addingTimeInterval(-3600), state: .recording))
        try wav("meeting_new.wav")

        let entries = Library.entries(in: dir)
        XCTAssertEqual(entries.map { $0.base.lastPathComponent }, ["meeting_new", "meeting_mid", "meeting_old"])

        let old = entries[2]
        let mid = entries[1]
        let new = entries[0]
        XCTAssertFalse(old.hasTranscript)
        XCTAssertFalse(old.hasReport)
        XCTAssertFalse(old.isUnfinished)
        XCTAssertEqual(old.audioFiles.map(\.lastPathComponent), ["meeting_old.m4a"])
        XCTAssertNil(old.topic)

        XCTAssertTrue(mid.hasTranscript)
        XCTAssertTrue(mid.hasReport)
        XCTAssertFalse(mid.isUnfinished)
        XCTAssertEqual(mid.topic, "Budget")
        XCTAssertEqual(mid.scenarioTitle, "Company meeting")
        XCTAssertEqual(mid.durationSeconds, 125)

        XCTAssertTrue(new.isUnfinished)
        XCTAssertEqual(new.audioFiles.map(\.lastPathComponent), ["meeting_new.wav"])
    }

    // Finding: a sidecar with nothing else (capture never started) is not listed.

    func testASidecarOnlyRecordingIsLeftOutAndItsSidecarStays() throws {
        try saveSidecar("meeting_empty", RecordingSidecar(createdAt: now, state: .recording))
        XCTAssertEqual(Library.entries(in: dir), [])
        XCTAssertTrue(exists("meeting_empty.mcmeta.json"), "listing must not delete the sidecar")
    }

    func testASidecarWithATranscriptStillShows() throws {
        try saveSidecar("meeting_t", RecordingSidecar(createdAt: now, state: .recording))
        try write("meeting_t.txt", transcript)
        let e = try entry("meeting_t")
        XCTAssertTrue(e.hasTranscript)
    }

    func testASidecarWithAnUnfinishedWAVStillShowsAsUnfinished() throws {
        var s = RecordingSidecar(createdAt: now, state: .recording)
        s.pid = nil
        try saveSidecar("meeting_w", s)
        try wav("meeting_w.wav")
        XCTAssertTrue(try entry("meeting_w").isUnfinished)
    }

    func testASidecarWithALivePidAndNoAudioIsLeftOut() throws {
        var s = RecordingSidecar(createdAt: now, state: .recording)
        s.pid = getpid()
        try saveSidecar("meeting_live2", s)
        XCTAssertEqual(Library.entries(in: dir), [])
        XCTAssertTrue(exists("meeting_live2.mcmeta.json"))
    }

    func testARecordingWhoseProcessIsStillRunningIsNotUnfinished() throws {
        var s = RecordingSidecar(createdAt: now, state: .recording)
        s.pid = getpid()
        s.audioFiles = ["meeting_live.wav"]
        try saveSidecar("meeting_live", s)
        try wav("meeting_live.wav")
        XCTAssertFalse(try entry("meeting_live").isUnfinished)
    }

    func testAReportWithoutASidecarIsStillListed() throws {
        try writeReport("meeting_20261101_090000", topic: "From a transcript")
        let e = try entry("meeting_20261101_090000")
        XCTAssertTrue(e.hasReport)
        XCTAssertEqual(e.topic, "From a transcript")
        XCTAssertTrue(e.audioFiles.isEmpty)
        XCTAssertFalse(e.isUnfinished)
        XCTAssertEqual(Library.entries(in: dir).count, 1)
    }

    func testFilesThatAreNotSidecarsOrReportsAreNotEntries() throws {
        try touch("meeting_loose.wav")
        try write("meeting_loose.txt", transcript)
        try touch("random.json")
        XCTAssertEqual(Library.entries(in: dir), [])
    }

    func testABrokenReportJSONGivesAnEntryWithoutAReport() throws {
        try saveSidecar("meeting_b", transcribed(ageDays: 1, files: ["meeting_b.m4a"]))
        try touch("meeting_b.m4a")
        try write("meeting_b.report.json", "{not json")
        let e = try entry("meeting_b")
        XCTAssertFalse(e.hasReport)
        XCTAssertNil(e.reportHTML())
    }

    // MARK: report page

    func testReportHTMLRendersFromTheReportJSON() throws {
        try saveSidecar("meeting_r", transcribed(ageDays: 1, files: []))
        try writeReport("meeting_r", topic: "Budget <b>plan</b>")
        let html = try XCTUnwrap(try entry("meeting_r").reportHTML())
        XCTAssertEqual(html, ReportRenderer.html(report(topic: "Budget <b>plan</b>")))
        XCTAssertTrue(html.contains("We agreed to ship."))
        XCTAssertFalse(html.contains("<b>plan</b>"), "text is escaped")
    }

    func testReportHTMLIsNilWithoutAReport() throws {
        try saveSidecar("meeting_n", transcribed(ageDays: 1, files: ["meeting_n.m4a"]))
        try touch("meeting_n.m4a")
        XCTAssertNil(try entry("meeting_n").reportHTML())
    }

    // MARK: speakers

    func testSpeakersListsLabelsInOrderOfFirstAppearance() throws {
        try saveSidecar("meeting_s", transcribed(ageDays: 1, files: []))
        try write("meeting_s.txt", transcript)
        XCTAssertEqual(try entry("meeting_s").speakers(), ["You", "Speaker 1", "Speaker 2"])
    }

    func testSpeakersWithoutATranscriptIsEmpty() throws {
        try saveSidecar("meeting_s", transcribed(ageDays: 1, files: ["meeting_s.m4a"]))
        try touch("meeting_s.m4a")
        XCTAssertEqual(try entry("meeting_s").speakers(), [])
    }

    func testRenameChangesOnlyThatLabelAndRemembersItInTheSidecar() throws {
        try saveSidecar("meeting_a", transcribed(ageDays: 1, files: []))
        try write("meeting_a.txt", transcript)
        // A similarly named recording and a stray file with the same words must not change.
        try saveSidecar("meeting_a2", transcribed(ageDays: 1, files: []))
        try write("meeting_a2.txt", transcript)
        try write("meeting_a_notes.txt", transcript)

        XCTAssertTrue(try entry("meeting_a").renameSpeaker("Speaker 1", to: "  Ana  "))
        let text = try String(contentsOf: url("meeting_a.txt"), encoding: .utf8)
        XCTAssertEqual(text, transcript.replacingOccurrences(of: "Speaker 1:", with: "Ana:"))
        XCTAssertTrue(text.contains("hi, the plan: ship"))
        XCTAssertEqual(loadSidecar("meeting_a")?.speakerNames["Speaker 1"], "Ana")
        XCTAssertEqual(try String(contentsOf: url("meeting_a2.txt"), encoding: .utf8), transcript)
        XCTAssertEqual(try String(contentsOf: url("meeting_a_notes.txt"), encoding: .utf8), transcript)
        XCTAssertTrue(loadSidecar("meeting_a2")?.speakerNames.isEmpty ?? false)
    }

    func testRenamingToAnotherSpeakerMergesThem() throws {
        try saveSidecar("meeting_m", transcribed(ageDays: 1, files: []))
        try write("meeting_m.txt", transcript)
        XCTAssertTrue(try entry("meeting_m").renameSpeaker("Speaker 2", to: "Speaker 1"))
        XCTAssertEqual(try entry("meeting_m").speakers(), ["You", "Speaker 1"])
    }

    func testEmptyOrColonNamesAreRefusedAndNothingChanges() throws {
        try saveSidecar("meeting_x", transcribed(ageDays: 1, files: []))
        try write("meeting_x.txt", transcript)
        for bad in ["", "   ", "A: B", ":", "line\nbreak"] {
            XCTAssertFalse(try entry("meeting_x").renameSpeaker("You", to: bad), "\(bad.debugDescription)")
        }
        XCTAssertEqual(try String(contentsOf: url("meeting_x.txt"), encoding: .utf8), transcript)
        XCTAssertTrue(loadSidecar("meeting_x")?.speakerNames.isEmpty ?? false)
    }

    func testRenameWithoutATranscriptThrowsRatherThanCreatingOne() throws {
        try saveSidecar("meeting_t", transcribed(ageDays: 1, files: ["meeting_t.m4a"]))
        try touch("meeting_t.m4a")
        XCTAssertThrowsError(try entry("meeting_t").renameSpeaker("You", to: "Ana"))
        XCTAssertFalse(exists("meeting_t.txt"))
    }

    // MARK: unfinished parts

    func testUnfinishedPartsListsEveryChunkOfTheRecording() throws {
        try saveSidecar("meeting_u", RecordingSidecar(createdAt: now, state: .recording))
        try wav("meeting_u.wav")
        try wav("meeting_u_part2.wav")
        try wav("meeting_u2.wav")  // another recording's file
        let parts = try entry("meeting_u").unfinishedParts.map(\.lastPathComponent)
        XCTAssertEqual(parts, ["meeting_u.wav", "meeting_u_part2.wav"])
    }

    // MARK: cleanOldAudio

    private func settings(days: Int) -> AppSettings {
        var c = Config()
        c.outputDirectory = dir.path
        c.audioRetentionDays = days
        return AppSettings(c)
    }

    func testCleanOldAudioDeletesOnlyListedFilesOfRecordingsPastRetention() throws {
        // Past retention, lists its raw and clean files.
        try saveSidecar("meeting_old", transcribed(ageDays: 60, files: ["meeting_old.m4a", "meeting_old_clean.m4a"]))
        for n in [
            "meeting_old.m4a", "meeting_old_clean.m4a", "meeting_old_unlisted.m4a", "meeting_old.txt",
            "meeting_old.html",
        ] {
            try touch(n)
        }
        // Inside retention.
        try saveSidecar("meeting_new", transcribed(ageDays: 5, files: ["meeting_new.m4a"]))
        try touch("meeting_new.m4a")
        // Never transcribed: its audio is all there is.
        try saveSidecar(
            "meeting_raw",
            RecordingSidecar(
                createdAt: now.addingTimeInterval(-90 * 86_400), state: .processed, audioFiles: ["meeting_raw.m4a"]))
        try touch("meeting_raw.m4a")
        // A sidecar that names someone else's file.
        try saveSidecar(
            "meeting_evil",
            transcribed(ageDays: 60, files: ["meeting_victim.m4a", "../escape.m4a", "meeting_evil.m4a"]))
        try touch("meeting_victim.m4a")
        try touch("meeting_evil.m4a")

        let deleted = Library.cleanOldAudio(settings: settings(days: 30), now: now).map(\.lastPathComponent).sorted()
        XCTAssertEqual(deleted, ["meeting_evil.m4a", "meeting_old.m4a", "meeting_old_clean.m4a"])
        for survivor in [
            "meeting_old_unlisted.m4a", "meeting_old.txt", "meeting_old.html", "meeting_new.m4a", "meeting_raw.m4a",
            "meeting_victim.m4a",
        ] {
            XCTAssertTrue(exists(survivor), "\(survivor) must survive")
        }
        XCTAssertFalse(exists("meeting_old.m4a"))
    }

    func testCleanOldAudioWithRetentionZeroDeletesNothing() throws {
        try saveSidecar("meeting_old", transcribed(ageDays: 400, files: ["meeting_old.m4a"]))
        try touch("meeting_old.m4a")
        XCTAssertEqual(Library.cleanOldAudio(settings: settings(days: 0), now: now), [])
        XCTAssertTrue(exists("meeting_old.m4a"))
    }
}
