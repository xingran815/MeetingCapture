import XCTest

@testable import MeetingCaptureCore

/// M5.2 re-check: cut before redaction. Notes and edits were cut to a length BEFORE they
/// were redacted, so a value split at the cut (`dana@exam`, half a phone number) no longer
/// matched a rule and its raw parts reached the LLM. `Redactor.safePrefix` moves the cut
/// back to the value's start. All values are invented.
final class GroupCutBeforeRedactionTests: GroupTestCase {

    private let email = "dana.zqxlocal@example.com"
    private let phone = "+1 415 555 0123"

    /// Text of `before` letters and spaces (no digits, no `@`), then `value`, then a tail.
    private func straddling(_ value: String, startingAt before: Int) -> String {
        let word = "lorem ipsum "
        var filler = String(repeating: word, count: before / word.count + 1)
        filler = String(filler.prefix(before))
        return filler + value + " and then the rest of the note goes on a while."
    }

    private func run(_ b: ScriptedBackend, notes: String? = nil, context: GroupContext?) async throws {
        _ = try await ReportFixtures.pipeline(b, redaction: true).run(
            transcript: transcriptText, notes: notes, context: context)
    }

    private func assertNoRawPart(of value: String, parts: [String], in b: ScriptedBackend, _ what: String) {
        let all = everything(b)
        XCTAssertFalse(all.contains(value), "\(what): the whole value")
        for p in parts { XCTAssertFalse(all.contains(p), "\(what): raw part “\(p)” reached a backend call") }
    }

    private func pastWithNotes(_ notes: String) throws -> GroupContext {
        var on = ReportEdits()
        on.sendNotesToLLM = true
        try addRecording("meeting_past", hoursAgo: 5, report: simpleReport(topic: "TopicPast"), edits: on, notes: notes)
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        return try XCTUnwrap(GroupContextBuilder.build(for: base))
    }

    // MARK: 1. a past report's notes, cut at 4,000 characters per report

    func testM52RecheckCutBeforeRedactionAnEmailStraddlingAPastReportsNotesCutNeverReachesABackend() async throws {
        let notes = straddling(email, startingAt: GroupContextBuilder.maxNotesPerReport - 8)
        XCTAssertTrue(notes.contains(email))
        let context = try pastWithNotes(notes)
        XCTAssertTrue(context.text.contains("lorem"), "the notes were used")
        let b = echoBackend()
        try await run(b, context: context)
        assertNoRawPart(of: email, parts: ["dana", "zqxlocal", "example.com", "@exam"], in: b, "email")
    }

    func testM52RecheckCutBeforeRedactionAPhoneStraddlingAPastReportsNotesCutNeverReachesABackend() async throws {
        let notes = straddling(phone, startingAt: GroupContextBuilder.maxNotesPerReport - 7)
        let context = try pastWithNotes(notes)
        XCTAssertTrue(context.text.contains("lorem"))
        let b = echoBackend()
        try await run(b, context: context)
        assertNoRawPart(of: phone, parts: ["0123", "555", "415"], in: b, "phone")
    }

    func testM52RecheckCutBeforeRedactionTheCutNotesStillCarryTheTextBeforeTheValue() throws {
        let notes = straddling(email, startingAt: GroupContextBuilder.maxNotesPerReport - 8)
        let context = try pastWithNotes(notes)
        XCTAssertTrue(context.text.contains("lorem ipsum"))
        XCTAssertFalse(context.text.contains("dana"), "the cut moved back to the value's start")
        XCTAssertFalse(context.text.contains("@"))
    }

    // MARK: 2. this report's own notes, cut at 100,000

    func testM52RecheckCutBeforeRedactionAnEmailStraddlingThisReportsOwnNotesCutNeverReachesABackend() async throws {
        let notes = straddling(email, startingAt: Notebook.maxNotes - 10)
        XCTAssertGreaterThan(notes.count, Notebook.maxNotes)
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try notes.write(to: Notebook.notesURL(forBase: base), atomically: true, encoding: .utf8)
        var on = ReportEdits()
        on.sendNotesToLLM = true
        try on.save(to: ReportEdits.url(forBase: base))
        let inputs = ReportInputs.gather(base: base, catalog: .builtIn)
        let sent = try XCTUnwrap(inputs.notes)
        XCTAssertLessThanOrEqual(sent.count, Notebook.maxNotes)
        XCTAssertGreaterThan(sent.count, Notebook.maxNotes - 100, "only a few characters given up")
        let b = echoBackend()
        try await run(b, notes: inputs.notes, context: nil)
        let input = try XCTUnwrap(b.calls(.normal).first).input
        XCTAssertTrue(input.contains(SummaryPipeline.notesHeading), "the notes did go")
        assertNoRawPart(of: email, parts: ["dana", "zqxlocal", "example.com", "@exam"], in: b, "own notes")
    }

    // MARK: 3. a hand-written edit over 6,000 characters in a past grouped report

    func testM52RecheckCutBeforeRedactionAnEmailStraddlingAnEditsCutNeverReachesABackend() async throws {
        var edits = ReportEdits()
        edits.overrides = [
            ContentEdit(
                section: "actions", item: 0, field: .text, original: Mark.replacedText,
                text: straddling(email, startingAt: SummaryPipeline.maxFieldLength - 9))
        ]
        try addRecording("meeting_past", hoursAgo: 5, report: markedReport(), edits: edits)
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        XCTAssertTrue(context.text.contains("lorem ipsum"), "the edit was applied")
        XCTAssertFalse(context.text.contains(Mark.replacedText))
        let b = echoBackend()
        try await run(b, context: context)
        assertNoRawPart(of: email, parts: ["dana", "zqxlocal", "example.com", "@exam"], in: b, "edit")
    }

    func testM52RecheckCutBeforeRedactionAnAppliedEditIsNoLongerThanTheFieldLimit() throws {
        var e = ReportEdits()
        e.overrides = [
            ContentEdit(
                section: "actions", item: 0, field: .text, original: Mark.replacedText,
                text: straddling(email, startingAt: SummaryPipeline.maxFieldLength - 9))
        ]
        let merged = Notebook.apply(e, to: markedReport()).report
        let text = try XCTUnwrap(merged.sections[1].items[0].text)
        XCTAssertLessThanOrEqual(text.count, SummaryPipeline.maxFieldLength)
        XCTAssertFalse(text.contains("dana"))
    }

    // MARK: 4. Redactor.safePrefix

    func testSafePrefixLeavesTextUnderTheLimitAlone() {
        XCTAssertEqual(Redactor.safePrefix("short note", maxCharacters: 100), "short note")
        XCTAssertEqual(Redactor.safePrefix("exactly ten", maxCharacters: 11), "exactly ten")
        XCTAssertEqual(Redactor.safePrefix("mail \(email)", maxCharacters: 100), "mail \(email)")
        XCTAssertEqual(Redactor.safePrefix("", maxCharacters: 0), "")
    }

    func testSafePrefixMovesACutInsideAMatchBackToTheMatchStart() {
        let text = "aaaa \(email) bbb"
        let start = 5
        for cut in (start + 1)..<(start + email.count) {
            XCTAssertEqual(Redactor.safePrefix(text, maxCharacters: cut), "aaaa ", "cut at \(cut) inside the email")
        }
        let p = "call \(phone) now"
        XCTAssertEqual(Redactor.safePrefix(p, maxCharacters: 10), "call ", "inside a phone number")
    }

    func testSafePrefixKeepsACutAtOrOutsideAMatchBoundary() {
        let text = "aaaa \(email) bbb"
        XCTAssertEqual(Redactor.safePrefix(text, maxCharacters: 5), "aaaa ", "right before the value")
        XCTAssertEqual(Redactor.safePrefix(text, maxCharacters: 3), "aaa")
        let end = 5 + email.count
        XCTAssertEqual(Redactor.safePrefix(text, maxCharacters: end), "aaaa \(email)", "right after the value")
        XCTAssertEqual(Redactor.safePrefix(text, maxCharacters: end + 2), "aaaa \(email) b")
    }

    func testSafePrefixNeverSplitsAnEmojiOrSurrogatePair() {
        let text = "ab😀cd👨\u{200D}👩\u{200D}👧e🇨🇭f" + String(repeating: "x", count: 10)
        for limit in 0..<text.count {
            let r = Redactor.safePrefix(text, maxCharacters: limit)
            XCTAssertTrue(text.hasPrefix(r), "limit \(limit): a prefix of the text")
            XCTAssertEqual(
                r.unicodeScalars.count, String(String.UnicodeScalarView(r.unicodeScalars)).unicodeScalars.count)
            // Whole characters only: the result is the first N characters for some N.
            XCTAssertEqual(r, String(text.prefix(r.count)), "limit \(limit)")
            XCTAssertFalse(
                r.utf16.last.map { UTF16.isLeadSurrogate($0) } ?? false, "ends on a lead surrogate at \(limit)")
        }
        XCTAssertEqual(Redactor.safePrefix(text, maxCharacters: 3), "ab😀")
    }

    func testSafePrefixIsNeverLongerThanTheLimitAndNeverLeavesPartOfAMatch() {
        let text = "x😀 call \(phone) or mail \(email) later 😀😀 and \(email)"
        for limit in 0...text.count {
            let r = Redactor.safePrefix(text, maxCharacters: limit)
            XCTAssertLessThanOrEqual(r.count, limit, "limit \(limit)")
            XCTAssertTrue(text.hasPrefix(r))
            // Whatever is in the result redacts to the same text as the full-text redaction of that part:
            // no half email, no half phone number.
            XCTAssertFalse(r.hasSuffix("dana"), "limit \(limit)")
            XCTAssertFalse(r.contains("@") && !r.contains(email), "a cut email at limit \(limit): \(r)")
            if r.contains("415") { XCTAssertTrue(r.contains(phone), "a cut phone number at limit \(limit): \(r)") }
        }
    }
}
