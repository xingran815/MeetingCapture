import XCTest

@testable import MeetingCaptureCore

/// Spec 05.1 / D-93, D-95: notes reach the model only when asked, redacted with the
/// transcript in one token space, and only at the sections step.
final class NotebookLLMTests: XCTestCase {

    private let email = "ana.invented@example.com"
    private var transcript: String { "[00:00:05] You: please write to \(email) today.\n[00:00:09] Speaker 1: ok" }
    private let notesText = "Zebra-note: follow up with the vendor."

    private func backend() -> ScriptedBackend {
        ScriptedBackend(onComplete: { call in
            switch call.tier {
            case .cheap: return Replies.classify("meeting")
            case .normal: return Replies.sections(["summary": ["A summary."]])
            case .frontier: return Replies.review(["summary": ["A summary."]])
            }
        })
    }

    private func everything(_ b: ScriptedBackend) -> String { b.calls.map { $0.system + "\n" + $0.input }.joined() }

    func testWithoutNotesNoBackendCallMentionsThem() async throws {
        let b = backend()
        _ = try await ReportFixtures.pipeline(b).run(transcript: transcript)
        XCTAssertFalse(everything(b).contains(SummaryPipeline.notesHeading))
        XCTAssertFalse(everything(b).contains("Zebra-note"))
    }

    func testNotesGoToTheSectionsCallOnlyUnderTheUsersNotesHeading() async throws {
        let b = backend()
        _ = try await ReportFixtures.pipeline(b).run(transcript: transcript, notes: notesText)
        let sections = try XCTUnwrap(b.calls(.normal).first)
        XCTAssertTrue(sections.input.contains(SummaryPipeline.notesHeading))
        XCTAssertTrue(sections.input.contains(notesText))
        XCTAssertGreaterThan(
            sections.input.range(of: notesText)!.lowerBound.utf16Offset(in: sections.input),
            sections.input.range(of: SummaryPipeline.notesHeading)!.lowerBound.utf16Offset(in: sections.input),
            "after the heading")
        for call in b.calls where call.tier != .normal {
            XCTAssertFalse(call.input.contains("Zebra-note"), "\(call.tier) input")
            XCTAssertFalse(call.input.contains(SummaryPipeline.notesHeading), "\(call.tier) input")
        }
        XCTAssertTrue(b.searches.flatMap { $0 }.allSatisfy { !$0.contains("Zebra") })
    }

    func testAnEmailInNotesAndTranscriptGetsOneTokenAndTheRawEmailNeverLeaves() async throws {
        let b = backend()
        _ = try await ReportFixtures.pipeline(b, redaction: true).run(
            transcript: transcript, notes: "cc \(email) about the plan")
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        XCTAssertFalse(everything(b).contains(email), "the raw email reaches no call")
        let tokens = Self.emailTokens(in: sections)
        XCTAssertEqual(tokens.count, 2, sections)
        XCTAssertEqual(Set(tokens).count, 1, "same value, same token: \(tokens)")
    }

    func testWithRedactionOffNotesAreSentAsWritten() async throws {
        let b = backend()
        _ = try await ReportFixtures.pipeline(b, redaction: false).run(transcript: transcript, notes: "cc \(email)")
        XCTAssertTrue(try XCTUnwrap(b.calls(.normal).first).input.contains(email))
    }

    func testWhitespaceOnlyNotesAreTreatedAsNone() async throws {
        let b = backend()
        _ = try await ReportFixtures.pipeline(b).run(transcript: transcript, notes: "  \n ")
        XCTAssertFalse(everything(b).contains(SummaryPipeline.notesHeading))
    }

    func testRedactTogetherGivesBothTextsTheSameTokensAndTheSeparatorNeverLeaks() {
        let r = SummaryPipeline.redactTogether(
            transcript: "mail \(email)", notes: "again \(email) and +1 415 555 0100", redaction: true)
        XCTAssertFalse(r.transcript.text.contains(email))
        XCTAssertFalse(try XCTUnwrap(r.notes).contains(email))
        XCTAssertFalse(r.transcript.text.contains("\u{1E}"))
        XCTAssertFalse(try XCTUnwrap(r.notes).contains("\u{1E}"))
        XCTAssertEqual(Self.emailTokens(in: r.transcript.text), Self.emailTokens(in: try XCTUnwrap(r.notes)))
    }

    static func emailTokens(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "<EMAIL_\\d+>")
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
