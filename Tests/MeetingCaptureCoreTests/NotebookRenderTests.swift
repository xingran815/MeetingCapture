import XCTest

@testable import MeetingCaptureCore

/// Spec 05.1 Done-when: "Edited text renders escaped; a test puts script tags in an edit,
/// a title and the notes."
final class NotebookRenderTests: NotebookTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try makeRecording()
        try Notebook.rename(base: base, to: hostile)
        try Notebook.saveNotes(base: base, hostile + "\n\nSecond " + hostile)
        try Notebook.saveEdits(
            base: base, ["actions#0#text": hostile, "actions#0#owner": hostile, "summary#0#text": hostile])
    }

    func testHostileTitleEditAndNotesRenderEscapedInHTMLWithOnlyThePagesOwnScript() throws {
        let h = try XCTUnwrap(Notebook.html(base: base))
        XCTAssertEqual(h.components(separatedBy: "<script").count - 1, 1, "only the page's own script tag")
        XCTAssertFalse(h.contains("<img"), "no raw img tag")
        XCTAssertFalse(h.contains("<script>alert"))
        XCTAssertTrue(h.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(h.contains("&lt;img src=x onerror=alert(2)&gt;"))
        XCTAssertFalse(h.contains("\"quoted\" 'single'"), "quotes are escaped too")
        XCTAssertTrue(h.contains("<title>&lt;script&gt;"), "title escaped")
        XCTAssertTrue(h.contains("id=\"notes\""))
        // The notes section is plain text: each occurrence of the payload is escaped.
        let notes = try XCTUnwrap(h.range(of: "id=\"notes\""))
        let tail = String(h[notes.lowerBound...])
        XCTAssertFalse(tail.contains("<img"))
    }

    func testHostileTextIsBackslashEscapedInMarkdown() throws {
        let p = page()
        let md = ReportRenderer.markdown(p.report, notes: p.notes)
        XCTAssertFalse(md.contains("<script>"), md)
        XCTAssertNil(md.range(of: "(?<!\\\\)<", options: .regularExpression), "every < is backslash-escaped: \(md)")
        XCTAssertTrue(md.contains("\\<script\\>alert(1)\\</script\\>"), md)
        XCTAssertTrue(md.contains("## Your notes"))
    }

    func testControlCharactersAreDroppedFromTitleAndNotesInTerminalText() throws {
        try Notebook.rename(base: base, to: "Red\u{1B}[31m title\u{07}")
        try Notebook.saveNotes(base: base, "line\u{1B}[2J one\nline two\u{08}")
        let p = page()
        let t = ReportRenderer.terminalSummary(p.report, notes: p.notes, ansi: false)
        XCTAssertFalse(t.contains("\u{1B}"), "no escape character reaches the terminal")
        XCTAssertFalse(t.contains("\u{07}") || t.contains("\u{08}"))
        XCTAssertTrue(t.contains("title") && t.contains("line two"))
        let c = ReportConsole.text(p.report, showTranscript: false, notes: p.notes)
        XCTAssertFalse(c.contains("\u{1B}"))
    }

    func testHostileEditsAreNeverTreatedAsHTMLInTheTerminalEither() throws {
        let p = page()
        let t = ReportRenderer.terminalSummary(p.report, notes: p.notes, ansi: false)
        XCTAssertTrue(t.contains("alert(1)"), "shown as text")
    }

    func testRerenderedPageOnDiskIsAlsoEscaped() throws {
        let name = "20261107_100200_Topic.html"
        try touch(name, contents: Data("old".utf8))
        try saveSidecar(
            recName, RecordingSidecar(createdAt: now, state: .processed, reportFiles: [name]))
        try Notebook.saveNotes(base: base, hostile)
        let h = try String(contentsOf: url(name), encoding: .utf8)
        XCTAssertEqual(h.components(separatedBy: "<script").count - 1, 1)
        XCTAssertTrue(h.contains("&lt;script&gt;"))
    }
}
