import XCTest

@testable import MeetingCaptureCore

/// Round 2: each test is named after the M5.1 review finding it came from.
final class NotebookReviewFindingTests: NotebookTestCase {

    private func entry() throws -> LibraryEntry {
        try XCTUnwrap(Library.entries(in: dir).first { $0.base.lastPathComponent == recName })
    }

    /// Really moves files out of the recording folder (into a temp "trash" beside it).
    private func movingRemover() throws -> Notebook.Remover {
        let bin = outside.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return { u in try FileManager.default.moveItem(at: u, to: bin.appendingPathComponent(u.lastPathComponent)) }
    }

    // M5.1 deep review #1
    func testNothingIsWrittenForARecordingThatWasMovedToTheTrash() throws {
        try makeFullRecording()
        let e = try entry()
        XCTAssertTrue(e.stillExists)
        try Notebook.trash(base: base, remover: try movingRemover())
        XCTAssertFalse(e.stillExists)

        func gone(_ f: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try f(), file: file, line: line) {
                XCTAssertEqual($0 as? NotebookError, .recordingGone, file: file, line: line)
            }
        }
        gone { try Notebook.saveNotes(base: base, "abc") }
        gone { try Notebook.rename(base: base, to: "T") }
        gone { try Notebook.setSendNotesToLLM(base: base, true) }
        // PRODUCT BUG if this fails: saveEdits loads the report first, so on a trashed base it
        // throws .noReport, not .recordingGone (it writes nothing, so only the error differs).
        gone { try Notebook.saveEdits(base: base, ["actions#0#text": "x"]) }
        XCTAssertFalse(exists(recName + ".notes.md"))
        XCTAssertFalse(exists(recName + ".edits.json"))
        XCTAssertEqual(try names(), [])
    }

    // M5.1 deep review #2
    func testSavingEditsReadBeforeTheReportWasWrittenAgainIsRefusedAndChangesNothing() throws {
        try makeRecording()
        try Notebook.rename(base: base, to: "Mine")
        let before = try bytes(recName + ".edits.json")
        let e = try entry()
        let fields = e.editableFields()
        try writeReportJSON(makeReport(summary: "A different summary."))
        XCTAssertThrowsError(try e.saveEdits(["summary#0#text": "My text"], readFrom: fields)) {
            XCTAssertEqual($0 as? NotebookError, .reportChanged)
        }
        XCTAssertEqual(try bytes(recName + ".edits.json"), before)
    }

    func testSavingEditsReadFromTheCurrentReportStillWorks() throws {
        try makeRecording()
        let e = try entry()
        try e.saveEdits(["summary#0#text": "My text"], readFrom: e.editableFields())
        XCTAssertEqual(try loadEdits().overrides.first?.text, "My text")
    }

    // M5.1 deep review #3 (fast part): without the dropped edits no written file shows them.
    func testAWriteAfterDroppingEditsShowsNoEditedTextInMarkdownOrHTML() throws {
        let src = try touch(recName + ".txt", contents: Data("x".utf8))
        try writeReportJSON(makeReport())
        try Notebook.saveEdits(base: base, ["summary#0#text": "ZEBRA edited"])
        let kept = try ReportFiles.write(makeReport(), nextTo: src, date: now)
        XCTAssertTrue(try String(contentsOf: kept.markdown, encoding: .utf8).contains("ZEBRA"))
        try Notebook.dropContentEdits(base: base)
        let dropped = try ReportFiles.write(makeReport(), nextTo: src, date: now.addingTimeInterval(60))
        XCTAssertFalse(try String(contentsOf: dropped.markdown, encoding: .utf8).contains("ZEBRA"))
        XCTAssertFalse(try String(contentsOf: dropped.html, encoding: .utf8).contains("ZEBRA"))
    }

    // M5.1 deep review #4
    private func owners(_ rows: [(String, String)]) -> Report {
        var r = makeReport()
        r.sections[1].items = rows.map { Report.Item(text: $0.0, owner: $0.1, due: "Monday") }
        return r
    }

    func testAnOwnerEditDoesNotMoveOntoADifferentItemThatHasTheSameOwner() throws {
        try writeReportJSON(owners([("A", "Unknown"), ("B", "Bob")]))
        try Notebook.saveEdits(base: base, ["actions#0#owner": "Alice"])
        XCTAssertEqual(try loadEdits().overrides.first?.itemText, "A")
        try writeReportJSON(owners([("C", "Bob"), ("D", "Unknown")]))
        let p = page()
        XCTAssertEqual(p.staleEdits, 1)
        XCTAssertEqual(p.report.sections[1].items.map(\.owner), ["Bob", "Unknown"], "D keeps its own owner")
    }

    func testATextEditStillMovesToItsUniqueItemAndStoresNoItemText() throws {
        try writeReportJSON(owners([("A", "x"), ("B", "y")]))
        try Notebook.saveEdits(base: base, ["actions#0#text": "A edited"])
        XCTAssertNil(try loadEdits().overrides.first?.itemText)
        try writeReportJSON(owners([("B", "y"), ("A", "x")]))
        XCTAssertEqual(page().report.sections[1].items.map(\.text), ["B", "A edited"])
    }

    func testKeepingAStaleOwnerEditRebasesItsItemTextToo() throws {
        try writeReportJSON(owners([("A", "Unknown"), ("B", "Bob")]))
        try Notebook.saveEdits(base: base, ["actions#0#owner": "Alice"])
        try writeReportJSON(owners([("A reworded", "Unknown"), ("B", "Bob")]))
        XCTAssertEqual(page().staleEdits, 1, "the item's own text changed")
        try Notebook.resolveStale(base: base, keep: true)
        XCTAssertEqual(try loadEdits().overrides.first?.itemText, "A reworded")
        XCTAssertEqual(page().staleEdits, 0)
        XCTAssertEqual(page().report.sections[1].items[0].owner, "Alice")
    }

    // M5.1 deep review #5
    func testANewRecordingConflictsWithOnlyTheUsersLayerOrReportOfAnOldOne() throws {
        XCTAssertNil(RecordingFiles.conflict(forNewRecordingAt: base))
        for suffix in [".notes.md", ".edits.json", ".report.json"] {
            let f = try touch(recName + suffix)
            XCTAssertNotNil(RecordingFiles.conflict(forNewRecordingAt: base), suffix)
            try FileManager.default.removeItem(at: f)
        }
        XCTAssertNil(RecordingFiles.conflict(forNewRecordingAt: base))
    }

    // M5.1 deep review #6 / security #2
    func testConfirmedTrashMovesOnlyFilesTheUserSawAndNotAPageAddedSince() throws {
        try makeFullRecording()
        let seen = try Notebook.trashPlan(base: base)
        let late = "20261107_100300_Late.html"
        try touch(late, contents: Data("late".utf8))
        var s = try XCTUnwrap(loadSidecar(recName))
        s.reportFiles = (s.reportFiles ?? []) + [late]
        try saveSidecar(recName, s)

        var moved: [String] = []
        try Notebook.trash(base: base, confirmed: seen) {
            moved.append($0.lastPathComponent)
            try FileManager.default.removeItem(at: $0)
        }
        XCTAssertEqual(Set(moved), Set(seen.files.map(\.lastPathComponent)))
        XCTAssertFalse(moved.contains(late))
        XCTAssertTrue(exists(late))
    }

    func testConfirmedTrashSkipsAFileThatLeftThePlanSinceItWasShown() throws {
        try makeFullRecording()
        let seen = try Notebook.trashPlan(base: base)
        try FileManager.default.removeItem(at: url(recName + "_part2.wav"))
        var moved: [String] = []
        try Notebook.trash(base: base, confirmed: seen) { moved.append($0.lastPathComponent) }
        XCTAssertFalse(moved.contains(recName + "_part2.wav"))
        XCTAssertEqual(moved.last, recName + ".mcmeta.json")
    }

    // M5.1 deep review #11
    func testEditsFromANewerVersionStillRenderButAreNeverChanged() throws {
        try makeRecording()
        let future = Data(#"{"version": 2, "userTitle": "Future"}"#.utf8)
        try future.write(to: edits)
        XCTAssertNotNil(try entry().reportHTML())
        XCTAssertThrowsError(try Notebook.rename(base: base, to: "x")) {
            XCTAssertEqual($0 as? NotebookError, .newerEdits(recName + ".edits.json"))
        }
        XCTAssertThrowsError(try Notebook.saveEdits(base: base, ["actions#0#text": "x"])) {
            XCTAssertEqual($0 as? NotebookError, .newerEdits(recName + ".edits.json"))
        }
        XCTAssertEqual(try bytes(recName + ".edits.json"), future)
    }

    // M5.1 security #3
    func testRerenderNeverWritesAPageAnotherRecordingListsEvenIfThisSidecarNamesItLast() throws {
        try makeRecording()
        let theirs = "20261107_090000_Theirs.html"
        try touch(theirs, contents: Data("their page".utf8))
        try saveSidecar(
            "other_20261107_090000",
            RecordingSidecar(createdAt: now, state: .processed, reportFiles: [theirs]))
        try saveSidecar(recName, RecordingSidecar(createdAt: now, state: .processed, reportFiles: [theirs]))
        try Notebook.saveNotes(base: base, "a note")
        try Notebook.rename(base: base, to: "Renamed")
        XCTAssertEqual(try bytes(theirs), Data("their page".utf8))
    }
}
