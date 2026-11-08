import XCTest

@testable import MeetingCaptureCore

/// D-97 (2026-11-08): the review step also gets the group's context, an item may carry
/// `source: "earlier"`, and the report marks it. Classify still never sees context.
final class GroupReviewContextTests: GroupTestCase {

    private let emailA = "ana.invented@example.com"
    private let emailB = "bob.invented@example.com"
    private let earlierItem = "EarlierFactZQX printer deadline"

    private func pastGroup(text: String? = nil) throws -> GroupContext {
        try addRecording(
            "meeting_past", hoursAgo: 5, report: simpleReport(topic: "TopicPast", text: text ?? earlierItem))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        return try XCTUnwrap(GroupContextBuilder.build(for: base))
    }

    private func run(
        _ b: ScriptedBackend, context: GroupContext?, transcript: String? = nil, redaction: Bool = true
    ) async throws -> SummaryOutcome {
        try await ReportFixtures.pipeline(b, redaction: redaction).run(
            transcript: transcript ?? transcriptText, context: context)
    }

    /// Replies with one item whose source is `earlier` in both the sections and the review step.
    private func earlierBackend(text: String = "A fact from the past") -> ScriptedBackend {
        let items = [
            Replies.item(text, source: "earlier"), Replies.item("Said now", source: "transcript"),
        ]
        return ScriptedBackend(onComplete: { call in
            switch call.tier {
            case .cheap: return Replies.classify("meeting")
            case .normal: return Replies.sectionsItems(["summary": items])
            case .frontier: return Replies.sectionsItems(["summary": items], changes: [], suggestions: [])
            }
        })
    }

    // MARK: 1. who gets the context

    func testD97ReviewInputCarriesTheHeadingAndAnEarlierItemInAGroupAndClassifyNeverDoes() async throws {
        let context = try pastGroup()
        let b = echoBackend()
        _ = try await run(b, context: context)
        let review = try XCTUnwrap(b.calls(.frontier).first).input
        XCTAssertTrue(review.contains(SummaryPipeline.contextHeading))
        XCTAssertTrue(review.contains(earlierItem))
        let classify = try XCTUnwrap(b.calls(.cheap).first)
        XCTAssertFalse(classify.input.contains(SummaryPipeline.contextHeading))
        XCTAssertFalse(classify.input.contains(earlierItem))
        XCTAssertFalse(classify.system.contains("earlier"), "the classifier prompt knows nothing of earlier reports")
    }

    func testD97ReviewGetsTheSameContextTextAsTheSectionsStepAndItComesAfterTheDraft() async throws {
        let context = try pastGroup()
        let b = echoBackend()
        _ = try await run(b, context: context)
        func after(_ s: String) throws -> String {
            let r = try XCTUnwrap(s.range(of: SummaryPipeline.contextHeading))
            return String(s[r.upperBound...])
        }
        let sections = try after(try XCTUnwrap(b.calls(.normal).first).input)
        let review = try after(try XCTUnwrap(b.calls(.frontier).first).input)
        XCTAssertEqual(sections, review, "same redacted text and heading")
        let input = try XCTUnwrap(b.calls(.frontier).first).input
        XCTAssertLessThan(
            try XCTUnwrap(input.range(of: "Said") ?? input.range(of: "A summary.")).lowerBound,
            try XCTUnwrap(input.range(of: SummaryPipeline.contextHeading)).lowerBound, "after the draft")
    }

    func testD97WithoutAGroupTheReviewGetsNoContext() async throws {
        let b = echoBackend()
        _ = try await run(b, context: nil)
        for call in b.calls {
            XCTAssertFalse(call.input.contains(SummaryPipeline.contextHeading), "\(call.tier)")
        }
        let empty = GroupContext(groupName: "G", text: "", redact: true, used: [], leftOut: [], notices: [])
        let b2 = echoBackend()
        _ = try await run(b2, context: empty)
        XCTAssertFalse(try XCTUnwrap(b2.calls(.frontier).first).input.contains(SummaryPipeline.contextHeading))
    }

    func testD97ThePromptsExplainEarlierOnlyWithContext() async throws {
        let context = try pastGroup()
        let withCtx = echoBackend()
        _ = try await run(withCtx, context: context)
        let without = echoBackend()
        _ = try await run(without, context: nil)
        for tier in [ModelTier.normal, .frontier] {
            XCTAssertTrue(try XCTUnwrap(withCtx.calls(tier).first).system.contains("earlier"), "\(tier) with context")
            XCTAssertFalse(
                try XCTUnwrap(without.calls(tier).first).system.lowercased().contains("earlier report"),
                "\(tier) without")
        }
    }

    // MARK: 2. the schemas

    func testD97SectionsAndReviewSchemasAllowEarlierInSourceOnlyWithContext() async throws {
        let context = try pastGroup()
        let withCtx = echoBackend()
        _ = try await run(withCtx, context: context)
        let without = echoBackend()
        _ = try await run(without, context: nil)
        for tier in [ModelTier.normal, .frontier] {
            XCTAssertTrue(
                try XCTUnwrap(withCtx.calls(tier).first).schema.contains("\"earlier\""), "\(tier) with context")
            XCTAssertFalse(
                try XCTUnwrap(without.calls(tier).first).schema.contains("earlier"), "\(tier) without context")
        }
        XCTAssertFalse(try XCTUnwrap(withCtx.calls(.cheap).first).schema.contains("earlier"), "classify never")
        // And straight from the builders.
        let t = ScenarioCatalog.builtIn.general
        for review in [false, true] {
            XCTAssertTrue(SummaryPipeline.sectionsSchema(t, review: review, earlier: true).contains("\"earlier\""))
            XCTAssertFalse(SummaryPipeline.sectionsSchema(t, review: review, earlier: false).contains("earlier"))
            XCTAssertFalse(SummaryPipeline.sectionsSchema(t, review: review).contains("earlier"), "off by default")
        }
    }

    // MARK: 3. an earlier item survives and renders its marker

    func testD97AnEarlierItemSurvivesIntoTheReportAndRendersInHTMLMarkdownAndTerminal() async throws {
        let context = try pastGroup()
        let hostileText = "Deadline <b>friday</b> & \"quoted\""
        let outcome = try await run(earlierBackend(text: hostileText), context: context)
        let item = try XCTUnwrap(items(outcome.report, "summary").first)
        XCTAssertEqual(item.source, "earlier")
        XCTAssertTrue(item.isEarlier)
        XCTAssertNotEqual(item.confidence, "unsure", "an earlier item isn't unsure by itself")
        XCTAssertFalse(try XCTUnwrap(items(outcome.report, "summary").last).isEarlier)

        let html = ReportRenderer.html(outcome.report)
        XCTAssertTrue(html.contains("from-earlier"), "the class")
        XCTAssertTrue(html.contains("<p class=\"earlier\">"))
        XCTAssertTrue(html.contains("From an earlier report"))
        XCTAssertTrue(html.contains("Deadline &lt;b&gt;friday&lt;/b&gt;"), "the text is escaped")
        XCTAssertFalse(html.contains("<b>friday</b>"))
        XCTAssertEqual(
            html.components(separatedBy: "<p class=\"earlier\">").count - 1, 1, "only the earlier item is marked")
        XSS.assertInert(html)

        let md = ReportRenderer.markdown(outcome.report)
        XCTAssertTrue(md.contains("_(from an earlier report, not said in this recording)_"), md)
        XCTAssertEqual(md.components(separatedBy: "_(from an earlier report").count - 1, 1)

        let text = ReportConsole.text(outcome.report, showTranscript: false)
        XCTAssertTrue(text.contains("[earlier report] "), text)
        XCTAssertEqual(text.components(separatedBy: "[earlier report]").count - 1, 1)
    }

    func testD97AnItemWithoutEarlierRendersNoMarker() async throws {
        let outcome = try await run(echoBackend(), context: nil)
        XCTAssertFalse(ReportRenderer.html(outcome.report).contains("<p class=\"earlier\">"))
        XCTAssertFalse(ReportRenderer.markdown(outcome.report).contains("from an earlier report"))
        XCTAssertFalse(ReportConsole.text(outcome.report, showTranscript: false).contains("[earlier report]"))
    }

    func testD97WithNoContextAnEarlierItemBecomesTranscriptUnsureWithAReason() async throws {
        let outcome = try await run(earlierBackend(), context: nil)
        let item = try XCTUnwrap(items(outcome.report, "summary").first)
        XCTAssertEqual(item.source, "transcript")
        XCTAssertFalse(item.isEarlier)
        XCTAssertTrue(item.isUnsure)
        XCTAssertFalse((item.reason ?? "").isEmpty)
        let html = ReportRenderer.html(outcome.report)
        XCTAssertFalse(html.contains("from-earlier"))
        XCTAssertTrue(html.contains("Unsure"))
    }

    func testD97AModelsOwnReasonOnAnEarlierItemWithNoContextIsKept() async throws {
        let b = ScriptedBackend(onComplete: { call in
            let item = Replies.item("Claimed", reason: "my own reason", source: "earlier")
            switch call.tier {
            case .cheap: return Replies.classify("meeting")
            default: return Replies.sectionsItems(["summary": [item]])
            }
        })
        let outcome = try await run(b, context: nil)
        XCTAssertEqual(items(outcome.report, "summary").first?.reason, "my own reason")
    }

    // MARK: 4. redaction reaches the review input the same way

    private func emailGroup() throws -> GroupContext {
        try pastGroup(text: "Follow up with \(emailA) and also \(emailB) on the budget.")
    }

    private var emailTranscript: String { "[00:00:05] You: please write to \(emailA) today.\n[00:00:09] Speaker 1: ok" }

    private func contextPart(_ input: String) throws -> String {
        let r = try XCTUnwrap(input.range(of: SummaryPipeline.contextHeading))
        return String(input[r.upperBound...])
    }

    func testD97WithRedactionOnTheReviewSeesTheSameTokensAsTheSectionsStepAndNeverTheRawValue() async throws {
        let context = try emailGroup()
        let b = echoBackend()
        _ = try await run(b, context: context, transcript: emailTranscript)
        let sections = try contextPart(try XCTUnwrap(b.calls(.normal).first).input)
        let review = try contextPart(try XCTUnwrap(b.calls(.frontier).first).input)
        XCTAssertEqual(Self.emailTokens(in: review), Self.emailTokens(in: sections))
        XCTAssertEqual(Self.emailTokens(in: review).count, 2)
        XCTAssertFalse(review.contains(emailA))
        XCTAssertFalse(review.contains(emailB))
        let all = b.calls.map { $0.system + $0.input }.joined()
        XCTAssertFalse(all.contains(emailA), "raw email in no call")
        XCTAssertFalse(all.contains(emailB))
        // The same value has the same token in the transcript part of the review input.
        let reviewInput = try XCTUnwrap(b.calls(.frontier).first).input
        let head = String(reviewInput[..<reviewInput.range(of: SummaryPipeline.contextHeading)!.lowerBound])
        XCTAssertTrue(Self.emailTokens(in: head).contains { Self.emailTokens(in: review).contains($0) })
    }

    func testD97WithTheGroupsSwitchOffTheReviewsContextGoesAsWrittenAndTheTranscriptStaysRedacted() async throws {
        _ = try emailGroup()
        let g = try XCTUnwrap(GroupStore.group(of: recName, in: dir))
        try GroupStore.setRedactContext(g.id, false, globalRedaction: true, in: dir)
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        let b = echoBackend()
        _ = try await run(b, context: context, transcript: emailTranscript)
        let reviewInput = try XCTUnwrap(b.calls(.frontier).first).input
        let ctx = try contextPart(reviewInput)
        XCTAssertTrue(ctx.contains(emailA))
        XCTAssertTrue(ctx.contains(emailB))
        let head = String(reviewInput[..<reviewInput.range(of: SummaryPipeline.contextHeading)!.lowerBound])
        XCTAssertFalse(head.contains(emailA), "the transcript and draft part stays redacted")
    }

    func testD97WithGlobalRedactionOffNothingIsRedactedInTheReviewInput() async throws {
        let context = try emailGroup()
        let b = echoBackend()
        _ = try await run(b, context: context, transcript: emailTranscript, redaction: false)
        let review = try XCTUnwrap(b.calls(.frontier).first).input
        XCTAssertTrue(try contextPart(review).contains(emailA))
        XCTAssertTrue(review.contains(emailA))
        XCTAssertTrue(Self.emailTokens(in: review).isEmpty)
    }

    // MARK: 5. excluded fields still never reach any call, review included

    func testD97NoExcludedMarkerReachesAnyCallIncludingTheReview() async throws {
        var edits = ReportEdits()
        edits.userTitle = Mark.userTitle
        try addRecording("meeting_past", hoursAgo: 5, report: markedReport(), edits: edits, notes: Mark.notesOff)
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        let b = echoBackend()
        _ = try await run(b, context: context)
        let review = try XCTUnwrap(b.calls(.frontier).first)
        XCTAssertTrue(review.input.contains(Mark.itemText), "the allow-list reaches the review")
        for call in b.calls {
            for m in Mark.excluded where m != Mark.replacedText {
                XCTAssertFalse(call.input.contains(m), "\(m) in the \(call.tier) input")
                XCTAssertFalse(call.system.contains(m), "\(m) in the \(call.tier) system prompt")
                XCTAssertFalse(call.schema.contains(m), "\(m) in the \(call.tier) schema")
            }
        }
    }

    // MARK: 6. the notice

    private let wording =
        "The review checked this report against its own transcript and the group's earlier reports. Facts kept only from an earlier report are marked \"From an earlier report\"."

    func testD97TheNoticeHasTheNewWordingOnlyWhenReviewedAndContextUsed() async throws {
        let context = try pastGroup()
        let ran = try await run(echoBackend(), context: context)
        XCTAssertTrue(ran.report.notices.contains(wording), "\(ran.report.notices)")
        XCTAssertFalse(ran.report.notices.joined().contains("its own transcript only"), "the old wording is gone")

        let failing = echoBackend()
        let inner = failing.onComplete
        failing.onComplete = { call in
            if call.tier == .frontier { throw StepFailure() }
            return try inner(call)
        }
        let failed = try await run(failing, context: context)
        XCTAssertFalse(failed.report.notices.contains(wording))

        var off = ReportFixtures.pipeline(echoBackend())
        off.review = false
        let skipped = try await off.run(transcript: transcriptText, context: context)
        XCTAssertFalse(skipped.report.notices.contains(wording))

        let none = try await run(echoBackend(), context: nil)
        XCTAssertFalse(none.report.notices.contains(wording))
    }
}
