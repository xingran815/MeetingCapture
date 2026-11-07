import XCTest

@testable import MeetingCaptureCore

/// Spec 05.1 Done-when: "Delete moves only the listed files to the Trash, sidecar last; a
/// test proves a similarly named file survives, and an old report's unrecorded HTML is
/// left with a message." (D-44, D-95.) The remover is a fake: the real Trash is never used.
final class NotebookTrashTests: NotebookTestCase {

    private let page = "20261107_100200_Model_topic.html"

    /// Records what it was asked to move and really deletes it (inside the temp folder).
    private func recorder(failOn: String? = nil) -> (Notebook.Remover, () -> [String]) {
        var moved: [String] = []
        let remover: Notebook.Remover = { u in
            if u.lastPathComponent == failOn { throw CocoaError(.fileWriteNoPermission) }
            moved.append(u.lastPathComponent)
            try FileManager.default.removeItem(at: u)
        }
        return (remover, { moved })
    }

    private func neverCalled() -> Notebook.Remover {
        { u in XCTFail("moved \(u.lastPathComponent)") }
    }

    private func bystanders() throws -> [String] {
        let names = [
            recName + "x.txt", recName + "_notes.txt", recName + ".txt.bak", recName + "_clean_notes.m4a",
            "other.html", "20261107_100200_Unlisted.html", recName + "2.m4a",
        ]
        for n in names { try touch(n, contents: Data("keep".utf8)) }
        return names
    }

    // MARK: moves exactly the listed files, sidecar last

    func testMovesExactlyTheListedFilesWithTheSidecarLastAndSimilarNamesSurvive() throws {
        try makeFullRecording()
        let keep = try bystanders()
        let (remover, moved) = recorder()
        let plan = try Notebook.trash(base: base, remover: remover)

        let expected: Set<String> = [
            recName + ".m4a", recName + "_clean.m4a", recName + "_part2.wav", page, recName + ".txt", recName + ".md",
            recName + ".report.md", recName + ".report.json", recName + ".edits.json", recName + ".notes.md",
            recName + ".mcmeta.json",
        ]
        XCTAssertEqual(Set(moved()), expected)
        XCTAssertEqual(moved().count, expected.count, "each once")
        XCTAssertEqual(moved().last, recName + ".mcmeta.json", "sidecar last")
        XCTAssertEqual(plan.files.last?.lastPathComponent, recName + ".mcmeta.json")
        for n in keep { XCTAssertTrue(exists(n), "\(n) must survive") }
        XCTAssertTrue(plan.notes.isEmpty, "\(plan.notes)")
    }

    func testPlanListsAudioThenPagesThenFixedNamesThenSidecarWithoutMovingAnything() throws {
        try makeFullRecording()
        let plan = try Notebook.trashPlan(base: base)
        let names = plan.files.map(\.lastPathComponent)
        XCTAssertLessThan(names.firstIndex(of: recName + ".m4a")!, names.firstIndex(of: page)!)
        XCTAssertLessThan(names.firstIndex(of: page)!, names.firstIndex(of: recName + ".txt")!)
        XCTAssertEqual(names.last, recName + ".mcmeta.json")
        XCTAssertEqual(names.count, try FileManager.default.contentsOfDirectory(atPath: dir.path).count)
    }

    func testAMissingListedFileIsSkippedNotAnError() throws {
        try makeFullRecording()
        try FileManager.default.removeItem(at: url(recName + "_part2.wav"))
        let (remover, moved) = recorder()
        XCTAssertNoThrow(try Notebook.trash(base: base, remover: remover))
        XCTAssertFalse(moved().contains(recName + "_part2.wav"))
    }

    // MARK: old reports (Done-when: unrecorded HTML is left with a message)

    func testAnOldReportWithoutReportFilesLeavesItsHTMLAndSaysSo() throws {
        try makeRecording()
        try touch(recName + ".m4a")
        try saveSidecar(recName, transcribed(ageDays: 3, files: [recName + ".m4a"]))
        try touch("20261106_090000_Old_topic.html", contents: Data("old".utf8))
        let (remover, moved) = recorder()
        let plan = try Notebook.trash(base: base, remover: remover)
        XCTAssertFalse(moved().contains("20261106_090000_Old_topic.html"))
        XCTAssertTrue(exists("20261106_090000_Old_topic.html"))
        XCTAssertTrue(plan.notes.contains { $0.contains("isn't listed, so it's left") }, "\(plan.notes)")
        XCTAssertEqual(moved().last, recName + ".mcmeta.json")
    }

    func testNoNoteWhenThereWasNoReportAtAll() throws {
        try touch(recName + ".m4a")
        try saveSidecar(recName, transcribed(ageDays: 3, files: [recName + ".m4a"]))
        let plan = try Notebook.trashPlan(base: base)
        XCTAssertEqual(plan.notes, [])
    }

    func testARecordingWithNoSidecarMovesOnlyTheFixedNamesAndNeverAudio() throws {
        try makeRecording()
        try touch(recName + ".m4a")
        let (remover, moved) = recorder()
        try Notebook.trash(base: base, remover: remover)
        XCTAssertEqual(Set(moved()), [recName + ".txt", recName + ".report.json"])
        XCTAssertTrue(exists(recName + ".m4a"), "audio isn't listed anywhere, so it is not guessed")
    }

    // MARK: hostile or damaged sidecars

    func testAHostileSidecarMovesNothingOutsideItsOwnPlainRegularFiles() throws {
        try makeRecording()
        let escape = outside.appendingPathComponent("escape.txt")
        try "secret".write(to: escape, atomically: true, encoding: .utf8)
        let abs = outside.appendingPathComponent("abs.wav")
        try "abs".write(to: abs, atomically: true, encoding: .utf8)
        // A folder named like a listed audio file, and links to a file elsewhere.
        try FileManager.default.createDirectory(at: url(recName + "_part2.wav"), withIntermediateDirectories: false)
        try "inside folder".write(to: url(recName + "_part2.wav/inner.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url(recName + "_part3.wav"), withDestinationURL: escape)
        try FileManager.default.createDirectory(at: url("dir.html"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: url("link.html"), withDestinationURL: escape)
        // Another recording's files, which this sidecar also claims.
        try touch("other_20261107_000000.m4a")
        try touch("claimed.html")
        try touch(recName + "_part4.wav")
        try saveSidecar(
            "other_20261107_000000",
            RecordingSidecar(
                createdAt: now, state: .processed, audioFiles: ["other_20261107_000000.m4a", recName + "_part4.wav"],
                reportFiles: ["claimed.html"]))
        try saveSidecar(
            recName,
            RecordingSidecar(
                createdAt: now, state: .processed, transcribedAt: now,
                audioFiles: [
                    "../escape.txt", escape.path, abs.path, recName + "_part2.wav", recName + "_part3.wav",
                    "other_20261107_000000.m4a", recName + "_part4.wav",
                ],
                reportFiles: ["../escape.html", "dir.html", "link.html", "claimed.html", escape.path]))

        let (remover, moved) = recorder()
        try Notebook.trash(base: base, remover: remover)
        XCTAssertEqual(Set(moved()), [recName + ".txt", recName + ".report.json", recName + ".mcmeta.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: escape.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: abs.path))
        XCTAssertTrue(exists(recName + "_part2.wav/inner.txt"))
        XCTAssertTrue(entryExists(recName + "_part3.wav"))
        XCTAssertTrue(entryExists("link.html") && exists("dir.html"))
        XCTAssertTrue(exists("other_20261107_000000.m4a") && exists("claimed.html"))
        XCTAssertTrue(exists(recName + "_part4.wav"), "listed by another sidecar, so it isn't this one's")
        XCTAssertTrue(exists("other_20261107_000000.mcmeta.json"))
    }

    func testAPartFileThatHasItsOwnSidecarIsNotTakenAlongWithThisRecording() throws {
        try makeRecording()
        try touch(recName + "_part2.wav")
        try saveSidecar(recName + "_part2", RecordingSidecar(createdAt: now, state: .processed, audioFiles: []))
        try saveSidecar(
            recName,
            RecordingSidecar(
                createdAt: now, state: .processed, transcribedAt: now, audioFiles: [recName + "_part2.wav"]))
        let (remover, moved) = recorder()
        try Notebook.trash(base: base, remover: remover)
        XCTAssertFalse(moved().contains(recName + "_part2.wav"))
        XCTAssertTrue(exists(recName + "_part2.wav"))
    }

    func testAnUnreadableSidecarThrowsAndNothingMoves() throws {
        try makeRecording()
        try Data("{broken".utf8).write(to: RecordingSidecar.url(forBase: base))
        XCTAssertThrowsError(try Notebook.trash(base: base, remover: neverCalled())) {
            XCTAssertEqual($0 as? NotebookError, .sidecarUnreadable)
        }
        XCTAssertThrowsError(try Notebook.trashPlan(base: base))
        XCTAssertTrue(exists(recName + ".txt") && exists(recName + ".report.json"))
    }

    // MARK: refusals

    func testAnUnfinishedRecordingIsRefusedAndNothingMoves() throws {
        try makeRecording()
        try wav(recName + ".wav")
        try saveSidecar(recName, RecordingSidecar(createdAt: now, state: .recording))
        XCTAssertThrowsError(try Notebook.trash(base: base, remover: neverCalled())) {
            XCTAssertEqual($0 as? NotebookError, .unfinished)
        }
        XCTAssertTrue(exists(recName + ".wav"))
    }

    func testARecordingStillBeingWrittenByAnotherLiveProcessIsRefused() throws {
        try makeRecording()
        // pid 1 (launchd) is alive and is not this process.
        var s = RecordingSidecar(createdAt: now, state: .recording)
        s.pid = 1
        try saveSidecar(recName, s)
        XCTAssertThrowsError(try Notebook.trash(base: base, remover: neverCalled())) {
            XCTAssertEqual($0 as? NotebookError, .recordingInProgress)
        }
    }

    func testABaseThatIsBusyIsRefusedAndNothingMoves() throws {
        try makeFullRecording()
        XCTAssertThrowsError(try Notebook.trash(base: base, busy: [recName], remover: neverCalled())) {
            XCTAssertEqual($0 as? NotebookError, .recordingInProgress)
        }
        XCTAssertThrowsError(try Notebook.trashPlan(base: base, busy: [recName]))
        XCTAssertTrue(exists(recName + ".mcmeta.json"))
    }

    func testABusyOtherRecordingDoesNotBlockThisOne() throws {
        try makeFullRecording()
        let (remover, moved) = recorder()
        XCTAssertNoThrow(try Notebook.trash(base: base, busy: ["something_else"], remover: remover))
        XCTAssertFalse(moved().isEmpty)
    }

    // MARK: a failure midway

    func testARemoverFailingMidwayStopsThereAndTheSidecarStaysListingWhatIsLeft() throws {
        try makeFullRecording()
        let (remover, moved) = recorder(failOn: recName + ".report.json")
        XCTAssertThrowsError(try Notebook.trash(base: base, remover: remover)) { error in
            guard case NotebookError.moveFailed(let name, _) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, recName + ".report.json")
        }
        XCTAssertFalse(moved().contains(recName + ".mcmeta.json"), "sidecar is not moved")
        XCTAssertTrue(exists(recName + ".mcmeta.json"))
        XCTAssertTrue(exists(recName + ".report.json"))
        XCTAssertNotNil(loadSidecar(recName), "still readable, still lists what's left")
        // Files before the failure are gone, the ones after are still there.
        let plan = try Notebook.trashPlan(base: base)
        XCTAssertTrue(plan.files.map(\.lastPathComponent).contains(recName + ".report.json"))
        XCTAssertFalse(plan.files.map(\.lastPathComponent).contains(moved().first!))
    }

    // MARK: through the library entry

    func testLibraryEntryPlanMatchesNotebookPlan() throws {
        try makeFullRecording()
        let entry = try XCTUnwrap(Library.entries(in: dir).first { $0.base.lastPathComponent == recName })
        XCTAssertEqual(try entry.trashPlan().files, try Notebook.trashPlan(base: base).files)
        XCTAssertEqual(try entry.trashPlan().files.last?.lastPathComponent, recName + ".mcmeta.json")
    }
}
