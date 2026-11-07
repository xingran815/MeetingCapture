import XCTest

@testable import MeetingCaptureCore

/// Spec 05.1: rename, notes and edits, merged at render time over the model's own report.
final class NotebookTests: NotebookTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try makeRecording()
    }

    private func entry() throws -> LibraryEntry {
        try XCTUnwrap(Library.entries(in: dir).first { $0.base.lastPathComponent == recName })
    }

    private func html() throws -> String { try XCTUnwrap(try entry().reportHTML()) }

    // MARK: 1. Rename (Done-when: rename works)

    func testRenameShowsInLibraryHTMLTitleAndTerminalButReportJSONKeepsTheModelTopic() throws {
        let json = try bytes(recName + ".report.json")
        try entry().rename(to: "Our budget call")

        XCTAssertEqual(try entry().topic, "Our budget call")
        XCTAssertEqual(try entry().userTitle, "Our budget call")
        let h = try html()
        XCTAssertTrue(h.contains("<h1>Our budget call</h1>"), "h1")
        XCTAssertTrue(h.contains("<title>Our budget call</title>"), "title")
        XCTAssertFalse(h.contains("Model topic"))
        let p = page()
        let text = ReportConsole.text(p.report, showTranscript: false, notes: p.notes)
        XCTAssertTrue(text.contains("Our budget call"), text)
        XCTAssertEqual(try bytes(recName + ".report.json"), json, "the model's topic stays in report.json")
        XCTAssertEqual(loadReportFromDisk().topic, "Model topic")
    }

    func testEmptyOrWhitespaceTitleGoesBackToTheModelTopic() throws {
        try entry().rename(to: "Mine")
        try entry().rename(to: "   ")
        XCTAssertEqual(try entry().topic, "Model topic")
        XCTAssertNil(try entry().userTitle)
        XCTAssertFalse(exists(recName + ".edits.json"), "nothing left to keep")
        XCTAssertTrue(try html().contains("<h1>Model topic</h1>"))
    }

    func testATitleOver200CharactersIsRefusedAndChangesNothing() throws {
        try entry().rename(to: "Keep me")
        let before = try bytes(recName + ".edits.json")
        XCTAssertThrowsError(try entry().rename(to: String(repeating: "x", count: 201))) {
            XCTAssertEqual($0 as? NotebookError, .tooLong(200))
        }
        XCTAssertEqual(try bytes(recName + ".edits.json"), before)
        XCTAssertNoThrow(try entry().rename(to: String(repeating: "y", count: 200)), "200 is allowed")
    }

    func testNewlinesInATitleAreCollapsedToSpaces() throws {
        try entry().rename(to: "Line one\nLine two\nLine three ")
        XCTAssertEqual(try loadEdits().userTitle, "Line one Line two Line three")
    }

    /// PRODUCT BUG (fails today): Notebook.oneLine splits on `.newlines`, which treats the
    /// CR and the LF of "\r\n" as two separators, so a pasted Windows-style title keeps a
    /// double space ("Two  Line"). Notebook.swift `oneLine`.
    func testACRLFInATitleBecomesOneSpace() throws {
        try entry().rename(to: "Line one\r\nLine two")
        XCTAssertEqual(try loadEdits().userTitle, "Line one Line two")
    }

    // MARK: 2. Notes (Done-when: notes work)

    func testNotesAreSavedBesideTheRecordingAndShownInHTMLMarkdownAndTerminal() throws {
        let e = try entry()
        try e.saveNotes("Ask Ana about the budget.\n\nSecond paragraph.")
        XCTAssertEqual(
            try String(contentsOf: url(recName + ".notes.md"), encoding: .utf8),
            "Ask Ana about the budget.\n\nSecond paragraph.", "saved as written")
        XCTAssertEqual(e.notes(), "Ask Ana about the budget.\n\nSecond paragraph.")
        let h = try html()
        XCTAssertTrue(h.contains("id=\"notes\""))
        XCTAssertTrue(h.contains("Ask Ana about the budget."))
        let p = page()
        XCTAssertEqual(p.notes, "Ask Ana about the budget.\n\nSecond paragraph.")
        XCTAssertTrue(ReportRenderer.markdown(p.report, notes: p.notes).contains("## Your notes"))
        XCTAssertTrue(ReportRenderer.markdown(p.report, notes: p.notes).contains("Ask Ana about the budget."))
        let t = ReportRenderer.terminalSummary(p.report, notes: p.notes, ansi: false)
        XCTAssertTrue(t.contains("YOUR NOTES") && t.contains("Ask Ana about the budget."), t)
    }

    func testWhitespaceOnlyNotesRemoveTheFileAndTheSection() throws {
        try entry().saveNotes("something")
        XCTAssertTrue(exists(recName + ".notes.md"))
        try entry().saveNotes("  \n\t \n")
        XCTAssertFalse(exists(recName + ".notes.md"))
        XCTAssertFalse(try html().contains("id=\"notes\""))
        XCTAssertNil(page().notes)
    }

    func testNotesOverTheLimitAreRefusedAndTheOldNotesStay() throws {
        try entry().saveNotes("old")
        XCTAssertThrowsError(try entry().saveNotes(String(repeating: "n", count: Notebook.maxNotes + 1))) {
            XCTAssertEqual($0 as? NotebookError, .tooLong(Notebook.maxNotes))
        }
        XCTAssertEqual(try entry().notes(), "old")
    }

    func testSendingNotesToTheLLMDefaultsOffAndTheSwitchIsKept() throws {
        XCTAssertFalse(try entry().sendsNotesToLLM)
        XCTAssertFalse(ReportEdits().sendNotesToLLM)
        try entry().setSendNotesToLLM(true)
        XCTAssertTrue(try entry().sendsNotesToLLM)
        try entry().rename(to: "T")
        XCTAssertTrue(try entry().sendsNotesToLLM, "a rename doesn't lose the switch")
        try entry().setSendNotesToLLM(false)
        try entry().rename(to: "")
        XCTAssertFalse(exists(recName + ".edits.json"))
    }

    // MARK: 4. Edits (Done-when: a re-run keeps edits, a changed original is reported not applied)

    private func texts(_ r: Report, _ section: String = "actions") -> [String?] {
        r.sections.first { $0.id == section }!.items.map(\.text)
    }

    func testSaveEditsKeepsTheModelsTextAsTheOriginalNeverAnEarlierEdit() throws {
        try Notebook.saveEdits(base: base, ["actions#1#text": "Fix the login bug"])
        try Notebook.saveEdits(base: base, ["actions#1#text": "Fix the login bug properly"])
        let o = try loadEdits().overrides
        XCTAssertEqual(o.count, 1, "the second save replaces the first")
        XCTAssertEqual(o[0].original, "Fix the bug")
        XCTAssertEqual(o[0].text, "Fix the login bug properly")
        XCTAssertEqual(texts(page().report), ["Write the spec", "Fix the login bug properly", "Call the vendor"])
        XCTAssertTrue(page().report.notices.contains { $0.contains("edited 1 part") })
        XCTAssertEqual(try entry().hasContentEdits, true)
    }

    func testEditingBackToTheModelTextRemovesTheOverride() throws {
        try Notebook.saveEdits(base: base, ["actions#1#text": "Changed"])
        try Notebook.saveEdits(base: base, ["actions#1#text": "Fix the bug"])
        XCTAssertEqual(try loadEdits().overrides, [])
        XCTAssertFalse(exists(recName + ".edits.json"))
        XCTAssertFalse(try entry().hasContentEdits)
    }

    func testEditableFieldsShowCurrentAndModelTextAndOneLineFieldsCollapseNewlines() throws {
        try Notebook.saveEdits(base: base, ["actions#0#owner": "Bo\nb", "actions#0#text": "Two\nlines"])
        let fields = Notebook.editableFields(base: base)
        let owner = try XCTUnwrap(fields.first { $0.id == "actions#0#owner" })
        XCTAssertEqual(owner.current, "Bo b")
        XCTAssertEqual(owner.modelText, "Ana")
        XCTAssertTrue(owner.isEdited)
        let text = try XCTUnwrap(fields.first { $0.id == "actions#0#text" })
        XCTAssertEqual(text.current, "Two\nlines", "multiline text keeps its newline")
        XCTAssertFalse(try XCTUnwrap(fields.first { $0.id == "actions#2#text" }).isEdited)
    }

    func testSaveEditsRefusesUnknownFieldsAndTooLongTextWithoutWriting() throws {
        XCTAssertThrowsError(try Notebook.saveEdits(base: base, ["actions#9#text": "x"])) {
            XCTAssertEqual($0 as? NotebookError, .noSuchField)
        }
        XCTAssertThrowsError(
            try Notebook.saveEdits(
                base: base, ["actions#0#text": String(repeating: "z", count: SummaryPipeline.maxFieldLength + 1)])
        ) { XCTAssertEqual($0 as? NotebookError, .tooLong(SummaryPipeline.maxFieldLength)) }
        XCTAssertFalse(exists(recName + ".edits.json"))
    }

    func testAnEditIsFoundAtTheUniqueItemItMovedTo() throws {
        try Notebook.saveEdits(base: base, ["actions#1#text": "Fix the login bug"])
        // The model now lists the same items in another order.
        try writeReportJSON(makeReport(actions: ["Fix the bug", "Call the vendor", "Write the spec"]))
        XCTAssertEqual(
            texts(page().report), ["Fix the login bug", "Call the vendor", "Write the spec"])
        XCTAssertEqual(page().staleEdits, 0)
    }

    func testAnEditWhoseOriginalAppearsTwiceAndMovedIsStaleNotGuessed() throws {
        try writeReportJSON(makeReport(actions: ["Same", "Other", "Same"]))
        try Notebook.saveEdits(base: base, ["actions#2#text": "Mine"])
        try writeReportJSON(makeReport(actions: ["Same", "Same", "Other"]))
        XCTAssertEqual(page().staleEdits, 1, "two candidates, neither at its place")
        XCTAssertEqual(texts(page().report), ["Same", "Same", "Other"])
    }

    func testAnEditWhoseOriginalChangedIsStaleNotAppliedAndSaidSoInPageAndHTML() throws {
        try Notebook.saveEdits(base: base, ["actions#1#text": "Fix the login bug"])
        try writeReportJSON(makeReport(actions: ["Write the spec", "Repair the defect", "Call the vendor"]))
        let p = page()
        XCTAssertEqual(p.staleEdits, 1)
        XCTAssertEqual(texts(p.report), ["Write the spec", "Repair the defect", "Call the vendor"])
        XCTAssertTrue(p.report.notices.contains { $0.contains("no longer match") }, "\(p.report.notices)")
        XCTAssertTrue(try html().contains("no longer match"))
        XCTAssertFalse(try html().contains("Fix the login bug"))
        XCTAssertEqual(try entry().staleEditCount(), 1)
    }

    func testKeepingAStaleEditPutsItBackOverTheTextNowAtItsPlace() throws {
        try Notebook.saveEdits(base: base, ["actions#1#text": "Fix the login bug"])
        try writeReportJSON(makeReport(actions: ["Write the spec", "Repair the defect", "Call the vendor"]))
        try entry().resolveStaleEdits(keep: true)
        let o = try loadEdits().overrides
        XCTAssertEqual(o.map(\.original), ["Repair the defect"])
        XCTAssertEqual(texts(page().report)[1], "Fix the login bug")
        XCTAssertEqual(try entry().staleEditCount(), 0)
    }

    func testKeepingAStaleEditWhoseItemIsGoneDropsIt() throws {
        try Notebook.saveEdits(base: base, ["actions#2#text": "Mine"])
        try writeReportJSON(makeReport(actions: ["Only one"]))
        try entry().resolveStaleEdits(keep: true)
        XCTAssertEqual(try loadEdits().overrides, [])
    }

    func testDroppingStaleEditsRemovesThemAndLeavesEditsThatStillMatch() throws {
        try Notebook.saveEdits(base: base, ["actions#1#text": "Mine 1", "actions#0#text": "Mine 0"])
        try writeReportJSON(makeReport(actions: ["Write the spec", "Repair the defect", "Call the vendor"]))
        try entry().resolveStaleEdits(keep: false)
        XCTAssertEqual(try loadEdits().overrides.map(\.text), ["Mine 0"])
        XCTAssertEqual(texts(page().report), ["Mine 0", "Repair the defect", "Call the vendor"])
    }

    func testDropContentEditsKeepsTitleNotesAndTheSwitch() throws {
        try Notebook.saveEdits(base: base, ["actions#0#text": "Mine"])
        try entry().rename(to: "Kept title")
        try entry().saveNotes("kept notes")
        try entry().setSendNotesToLLM(true)
        try Notebook.dropContentEdits(base: base)
        let e = try loadEdits()
        XCTAssertEqual(e.overrides, [])
        XCTAssertEqual(e.userTitle, "Kept title")
        XCTAssertTrue(e.sendNotesToLLM)
        XCTAssertEqual(try entry().notes(), "kept notes")
        XCTAssertEqual(texts(page().report)[0], "Write the spec")
    }

    func testEditsWithoutAReportAreRefused() throws {
        try FileManager.default.removeItem(at: Notebook.reportURL(forBase: base))
        XCTAssertThrowsError(try Notebook.saveEdits(base: base, ["actions#0#text": "x"]))
        XCTAssertThrowsError(try Notebook.resolveStale(base: base, keep: true)) {
            XCTAssertEqual($0 as? NotebookError, .noReport)
        }
    }

    // MARK: 6. Unreadable edits.json

    func testUnreadableEditsStillRenderWithANoticeAndChangesThrowLeavingTheFileUntouched() throws {
        let junk = Data("{ this is not json".utf8)
        try junk.write(to: edits)
        let p = page()
        XCTAssertTrue(p.report.notices.contains { $0.contains("edits.json") }, "\(p.report.notices)")
        XCTAssertEqual(p.report.topic, "Model topic")
        XCTAssertNotNil(try entry().reportHTML(), "the report still renders")
        XCTAssertThrowsError(try entry().rename(to: "New")) {
            XCTAssertEqual($0 as? NotebookError, .editsUnreadable(recName + ".edits.json"))
        }
        XCTAssertThrowsError(try Notebook.saveEdits(base: base, ["actions#0#text": "x"]))
        XCTAssertThrowsError(try entry().setSendNotesToLLM(true))
        XCTAssertThrowsError(try entry().resolveStaleEdits(keep: true))
        XCTAssertThrowsError(try Notebook.dropContentEdits(base: base))
        XCTAssertEqual(try bytes(recName + ".edits.json"), junk, "byte for byte")
    }

    func testAnEditsFileMissingFieldsStillLoads() throws {
        try Data(#"{"userTitle": "Hand written"}"#.utf8).write(to: edits)
        XCTAssertEqual(try entry().topic, "Hand written")
        XCTAssertFalse(try entry().sendsNotesToLLM)
    }

    // MARK: 7. Sidecar reportFiles

    /// A transcript with no report yet (setUp made one, so it goes).
    private func looseTranscript() throws -> URL {
        try? FileManager.default.removeItem(at: Notebook.reportURL(forBase: base))
        return try touch(recName + ".txt", contents: Data("[00:00:01] You: hi\n".utf8))
    }

    func testEachReportWriteAppendsItsPageNameToTheSidecarInOrder() throws {
        try saveSidecar(recName, transcribed(ageDays: 0, files: [recName + ".m4a"]))
        try touch(recName + ".m4a")
        let src = try looseTranscript()
        let a = try ReportFiles.write(makeReport(topic: "First"), nextTo: src, date: now)
        let b = try ReportFiles.write(makeReport(topic: "Second"), nextTo: src, date: now.addingTimeInterval(60))
        let files = try XCTUnwrap(loadSidecar(recName)?.reportFiles)
        XCTAssertEqual(files, [a.html.lastPathComponent, b.html.lastPathComponent])
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(loadSidecar(recName)?.audioFiles, [recName + ".m4a"], "audio list untouched")
        XCTAssertNotEqual(loadSidecar(recName)?.olderPagesUnrecorded, true, "no report before the first write")
        for f in files { XCTAssertTrue(exists(f)) }
    }

    func testALooseTranscriptGetsAMinimalSidecarWithNoAudioList() throws {
        let src = try looseTranscript()
        let w = try ReportFiles.write(makeReport(), nextTo: src, date: now)
        let s = try XCTUnwrap(loadSidecar(recName))
        XCTAssertEqual(s.state, .processed)
        XCTAssertNil(s.audioFiles)
        XCTAssertEqual(s.reportFiles, [w.html.lastPathComponent])
        XCTAssertNil(s.transcribedAt, "no claim that audio was transcribed, so retention can't delete anything")
    }

    func testAnUnreadableSidecarIsLeftByteForByteWhenAReportIsWritten() throws {
        let junk = Data("not a sidecar at all".utf8)
        try junk.write(to: RecordingSidecar.url(forBase: base))
        let w = try ReportFiles.write(makeReport(), nextTo: try looseTranscript(), date: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.html.path), "the report is still written")
        XCTAssertEqual(try bytes(recName + ".mcmeta.json"), junk)
    }

    func testRenameRerendersTheNewestPageOnlyAndLeavesOlderPagesAsTheyWere() throws {
        try saveSidecar(recName, transcribed(ageDays: 0, files: []))
        let src = try looseTranscript()
        let first = try ReportFiles.write(makeReport(topic: "First topic"), nextTo: src, date: now)
        let second = try ReportFiles.write(
            makeReport(topic: "Second topic"), nextTo: src, date: now.addingTimeInterval(60))
        let olderBefore = try Data(contentsOf: first.html)
        try Notebook.rename(base: base, to: "Renamed")
        XCTAssertTrue(try String(contentsOf: second.html, encoding: .utf8).contains("<h1>Renamed</h1>"))
        XCTAssertEqual(try Data(contentsOf: first.html), olderBefore)
        try Notebook.saveNotes(base: base, "Note in page")
        XCTAssertTrue(try String(contentsOf: second.html, encoding: .utf8).contains("Note in page"))
        XCTAssertFalse(try String(contentsOf: first.html, encoding: .utf8).contains("Note in page"))
    }

    func testARewriteMergesTheUsersTitleAndNotesIntoTheNewPagesAndMarkdownButNotIntoReportJSON() throws {
        let src = try looseTranscript()
        try Notebook.rename(base: base, to: "Mine")
        try Notebook.saveNotes(base: base, "Remember the milk")
        let w = try ReportFiles.write(makeReport(topic: "Model again"), nextTo: src, date: now)
        let h = try String(contentsOf: w.html, encoding: .utf8)
        XCTAssertTrue(h.contains("<h1>Mine</h1>") && h.contains("Remember the milk"))
        let md = try String(contentsOf: w.markdown, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Mine") && md.contains("Remember the milk"))
        XCTAssertEqual(loadReportFromDisk().topic, "Model again")
        XCTAssertEqual(try loadEdits().userTitle, "Mine", "the user's layer survives a re-run")
    }

    func testABeforeM51ReportWrittenOnceMoreRecordsTheNewPageFlagsTheOldOneAndDeleteLeavesIt() throws {
        // Pre-M5.1: sidecar without reportFiles, a report.json and an old dated page.
        try touch(recName + ".m4a", contents: Data("a".utf8))
        try saveSidecar(recName, transcribed(ageDays: 1, files: [recName + ".m4a"]))
        try makeRecording()
        try touch("20261106_090000_Old_topic.html", contents: Data("old page".utf8))
        XCTAssertNil(loadSidecar(recName)?.reportFiles)

        let w = try ReportFiles.write(makeReport(topic: "New topic"), nextTo: url(recName + ".txt"), date: now)
        let s = try XCTUnwrap(loadSidecar(recName))
        XCTAssertEqual(s.reportFiles, [w.html.lastPathComponent])
        XCTAssertEqual(s.olderPagesUnrecorded, true)

        var removed: [URL] = []
        let plan = try Notebook.trash(base: base) { removed.append($0) }
        XCTAssertTrue(removed.contains(w.html), "the new page is listed, so it moves")
        XCTAssertFalse(removed.map(\.lastPathComponent).contains("20261106_090000_Old_topic.html"))
        XCTAssertEqual(removed.last?.lastPathComponent, recName + ".mcmeta.json")
        XCTAssertTrue(plan.notes.contains { $0.contains("isn't listed, so it's left") }, "\(plan.notes)")
        XCTAssertTrue(exists("20261106_090000_Old_topic.html"), "nothing was really removed by the fake remover")
    }
}
