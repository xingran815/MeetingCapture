import XCTest

@testable import MeetingCaptureCore

/// Spec 05.2 / D-94 Done-when, through the real pipeline with a scripted backend: what
/// reaches each model call, one token space, and the group's redaction switch.
final class GroupPipelineTests: GroupTestCase {

    private let emailA = "ana.invented@example.com"
    private let emailB = "bob.invented@example.com"

    /// A group of this recording plus the marked past report (notes switch off) and a
    /// second past report whose notes switch is on.
    private func markedGroup() throws -> GroupContext {
        var edits = ReportEdits()
        edits.userTitle = Mark.userTitle
        edits.overrides = [
            ContentEdit(section: "actions", item: 0, field: .text, original: Mark.replacedText, text: Mark.editedText)
        ]
        try addRecording("meeting_past", hoursAgo: 5, report: markedReport(), edits: edits, notes: Mark.notesOff)
        var on = ReportEdits()
        on.sendNotesToLLM = true
        try addRecording(
            "meeting_notes_on", hoursAgo: 7, report: simpleReport(topic: "TopicNotesOn"), edits: on,
            notes: Mark.notesOn)
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past", "meeting_notes_on"])
        return try XCTUnwrap(GroupContextBuilder.build(for: base))
    }

    private func run(
        _ b: ScriptedBackend, context: GroupContext?, transcript: String? = nil, redaction: Bool = true,
        forced: String? = nil
    ) async throws -> SummaryOutcome {
        try await ReportFixtures.pipeline(b, redaction: redaction).run(
            transcript: transcript ?? transcriptText, forcedScenario: forced, context: context)
    }

    // MARK: Done-when: nothing excluded reaches any call; the allow-list does reach the sections call

    func testNoMarkerFromAnExcludedFieldReachesAnyCallOrPrompt() async throws {
        let context = try markedGroup()
        let b = echoBackend()
        _ = try await run(b, context: context)
        XCTAssertGreaterThanOrEqual(b.calls.count, 3, "classify, sections and review all ran")
        for call in b.calls {
            for marker in Mark.excluded {
                XCTAssertFalse(call.input.contains(marker), "\(marker) in the \(call.tier) input")
                XCTAssertFalse(call.system.contains(marker), "\(marker) in the \(call.tier) system prompt")
                XCTAssertFalse(call.schema.contains(marker), "\(marker) in the \(call.tier) schema")
            }
        }
        for marker in Mark.excluded {
            XCTAssertFalse(b.searches.flatMap { $0 }.joined().contains(marker), "\(marker) in a concept search")
        }
    }

    func testTheAllowListedFieldsReachTheSectionsCall() async throws {
        let context = try markedGroup()
        let b = echoBackend()
        _ = try await run(b, context: context)
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        XCTAssertTrue(sections.contains(SummaryPipeline.contextHeading))
        for (what, needle) in [
            ("the user's title", Mark.userTitle), ("the scenario title", Mark.scenarioTitle),
            ("a section title", Mark.sectionA), ("another section title", Mark.sectionB),
            ("item text", Mark.itemText), ("item detail", Mark.itemDetail), ("a low item", Mark.lowText),
            ("high priority marking", "[key] "), ("low priority marking", "[background] "),
            ("keywords", "Keywords: budget"), ("the user's edit", Mark.editedText),
            ("notes with the switch on", Mark.notesOn),
        ] {
            XCTAssertTrue(sections.contains(needle), "\(what) (\(needle)) missing from the sections input")
        }
        XCTAssertFalse(sections.contains(Mark.replacedText), "the text the user replaced")
        XCTAssertFalse(sections.contains(Mark.modelTopic), "the user's title wins over the model's topic")
        XCTAssertFalse(sections.contains(Mark.notesOff), "notes with that report's switch off")
    }

    // D-97: context goes to the sections AND the review step, never the classifier.
    func testContextGoesToTheSectionsAndReviewStepsNeverTheClassifier() async throws {
        let context = try markedGroup()
        let b = echoBackend()
        _ = try await run(b, context: context)
        XCTAssertEqual(b.calls(.cheap).count, 1)
        XCTAssertEqual(b.calls(.normal).count, 1)
        XCTAssertEqual(b.calls(.frontier).count, 1)
        let needles = [
            SummaryPipeline.contextHeading, "EARLIER REPORT", Mark.userTitle, Mark.sectionA, Mark.itemText,
            Mark.notesOn,
            Mark.itemDetail, Mark.scenarioTitle, "EARLIER REPORTS IN THIS GROUP",
        ]
        let classify = try XCTUnwrap(b.calls(.cheap).first)
        for n in needles {
            XCTAssertFalse(classify.input.contains(n), "\(n) reached the classify input")
            XCTAssertFalse(classify.system.contains(n), "\(n) reached the classify system prompt")
        }
        for tier in [ModelTier.normal, .frontier] {
            let input = try XCTUnwrap(b.calls(tier).first).input
            for n in needles { XCTAssertTrue(input.contains(n), "\(n) missing from the \(tier) input") }
        }
    }

    func testContextComesAfterTheTranscriptAndNeverInsideIt() async throws {
        let context = try markedGroup()
        let b = echoBackend()
        _ = try await run(b, context: context)
        let input = try XCTUnwrap(b.calls(.normal).first).input
        let transcriptEnd = try XCTUnwrap(input.range(of: "Speaker 1: ok"))
        let heading = try XCTUnwrap(input.range(of: SummaryPipeline.contextHeading))
        XCTAssertLessThan(transcriptEnd.upperBound, heading.lowerBound)
    }

    func testWithoutContextTheSectionsInputIsExactlyAsBefore() async throws {
        let b1 = echoBackend()
        _ = try await run(b1, context: nil)
        let b2 = echoBackend()
        _ = try await run(
            b2, context: GroupContext(groupName: "G", text: "", redact: true, used: [], leftOut: [], notices: []))
        XCTAssertEqual(try XCTUnwrap(b1.calls(.normal).first).input, try XCTUnwrap(b2.calls(.normal).first).input)
        XCTAssertFalse(try XCTUnwrap(b1.calls(.normal).first).input.contains(SummaryPipeline.contextHeading))
        XCTAssertFalse(
            try XCTUnwrap(b2.calls(.normal).first).input.contains(SummaryPipeline.contextHeading),
            "an empty context adds no heading")
    }

    // MARK: Done-when: the report names what it used and left out

    func testTheWrittenReportNamesTheReportsUsedAndLeftOut() async throws {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "TopicA"))
        try addRecording("meeting_norep", hoursAgo: 4, report: nil)
        try addRecording("meeting_later", hoursAgo: -4, report: simpleReport(topic: "TopicLater"))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_a", "meeting_norep", "meeting_later", "meeting_gone"])
        let inputs = ReportInputs.gather(base: base, catalog: .builtIn)
        let outcome = try await run(echoBackend(), context: inputs.context)
        let notices = outcome.report.notices.joined(separator: "\n")
        XCTAssertTrue(notices.contains("\"TopicA\""), notices)
        XCTAssertTrue(notices.contains("\"meeting_norep\" (no report yet)"), notices)
        XCTAssertTrue(notices.contains("\"TopicLater\" (recorded after this one)"), notices)
        XCTAssertTrue(notices.contains("\"meeting_gone\" (its files are gone)"), notices)
    }

    func testAReportInAGroupWithNothingUsableSaysSoInItsNotices() async throws {
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName])
        let outcome = try await run(echoBackend(), context: GroupContextBuilder.build(for: base))
        XCTAssertTrue(outcome.report.notices.joined().contains("no other report in it was used"))
    }

    func testAReportWithoutAGroupGetsNoGroupNotices() async throws {
        let outcome = try await run(echoBackend(), context: nil)
        XCTAssertFalse(outcome.report.notices.joined().contains("group"), "\(outcome.report.notices)")
    }

    func testD97TheReviewIsToldAboutThePastReportsAfterTheDraft() async throws {
        let context = try markedGroup()
        let b = echoBackend()
        let outcome = try await run(b, context: context)
        XCTAssertTrue(outcome.report.reviewed)
        let review = try XCTUnwrap(b.calls(.frontier).first)
        let heading = try XCTUnwrap(review.input.range(of: SummaryPipeline.contextHeading))
        XCTAssertTrue(review.input[heading.upperBound...].contains(Mark.itemText))
        XCTAssertFalse(review.input[..<heading.lowerBound].contains(Mark.itemText), "only under the heading")
    }

    // MARK: Done-when: one token space, the group's switch, global redaction

    private func emailGroup() throws -> GroupContext {
        try addRecording(
            "meeting_past", hoursAgo: 5,
            report: simpleReport(topic: "TopicPast", text: "Follow up with \(emailA) and also \(emailB) on the budget.")
        )
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        return try XCTUnwrap(GroupContextBuilder.build(for: base))
    }

    private var emailTranscript: String { "[00:00:05] You: please write to \(emailA) today.\n[00:00:09] Speaker 1: ok" }

    func testWithRedactionOnAValueInTheTranscriptAndInAPastReportGetsOneTokenAndIsRestored() async throws {
        let context = try emailGroup()
        let b = echoBackend()
        let outcome = try await run(b, context: context, transcript: emailTranscript)
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        XCTAssertFalse(everything(b).contains(emailA), "the raw email reaches no call")
        XCTAssertFalse(everything(b).contains(emailB), "nor the other one in the past report")
        let tokensA = Self.emailTokens(in: sections)
        // emailA in the transcript and in the context, emailB in the context.
        XCTAssertEqual(tokensA.count, 3, sections)
        XCTAssertEqual(Set(tokensA).count, 2, "two values, two tokens; emailA has one token in both places: \(tokensA)")
        let transcriptPart = String(sections[..<sections.range(of: SummaryPipeline.contextHeading)!.lowerBound])
        let contextPart = String(sections[sections.range(of: SummaryPipeline.contextHeading)!.upperBound...])
        let inTranscript = try XCTUnwrap(Self.emailTokens(in: transcriptPart).first)
        XCTAssertTrue(contextPart.contains(inTranscript), "the same token in the context as in the transcript")
        // Restored in the final report: the echo backend writes the first token it saw, emailA's.
        let text = allText(outcome.report)
        XCTAssertTrue(items(outcome.report, "summary").contains { ($0.text ?? "").contains(emailA) }, text)
        XCTAssertFalse(text.contains("<EMAIL_"), "no token is left in the report: \(text)")
    }

    func testWithTheGroupsSwitchOffTheContextGoesAsWrittenAndTheTranscriptIsStillRedacted() async throws {
        _ = try emailGroup()
        let g = try XCTUnwrap(GroupStore.group(of: recName, in: dir))
        try GroupStore.setRedactContext(g.id, false, globalRedaction: true, in: dir)
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        XCTAssertFalse(context.redact)
        let b = echoBackend()
        let outcome = try await run(b, context: context, transcript: emailTranscript)
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        let cut = try XCTUnwrap(sections.range(of: SummaryPipeline.contextHeading))
        let transcriptPart = String(sections[..<cut.lowerBound])
        let contextPart = String(sections[cut.upperBound...])
        XCTAssertFalse(transcriptPart.contains(emailA), "the transcript is still redacted")
        XCTAssertEqual(Self.emailTokens(in: transcriptPart).count, 1)
        XCTAssertTrue(contextPart.contains(emailA), "the context's value goes as written")
        XCTAssertTrue(contextPart.contains(emailB))
        XCTAssertTrue(Self.emailTokens(in: contextPart).isEmpty, "no token in the context")
        XCTAssertTrue(
            outcome.report.notices.joined().contains("switch is off"), "the report says so: \(outcome.report.notices)")
        XCTAssertFalse(allText(outcome.report).contains("<EMAIL_"))
    }

    func testWithGlobalRedactionOffNothingIsRedactedAndNoSwitchNoticeIsAdded() async throws {
        let context = try emailGroup()
        XCTAssertTrue(context.redact, "the group's own switch is on")
        let b = echoBackend()
        let outcome = try await run(b, context: context, transcript: emailTranscript, redaction: false)
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        XCTAssertEqual(sections.components(separatedBy: emailA).count - 1, 2, "emailA twice, as written")
        XCTAssertTrue(sections.contains(emailB))
        XCTAssertTrue(Self.emailTokens(in: sections).isEmpty)
        XCTAssertFalse(outcome.report.notices.joined().contains("switch is off"), "\(outcome.report.notices)")
    }

    func testAGroupCannotTurnItsSwitchOnWhenGlobalRedactionIsOff() throws {
        let g = try GroupStore.create(named: "Series", in: dir)
        XCTAssertThrowsError(try GroupStore.setRedactContext(g.id, true, globalRedaction: false, in: dir)) {
            XCTAssertEqual($0 as? GroupError, .redactionOffGlobally)
        }
    }

    func testRedactTogetherHandlesEveryCombinationOfSwitches() {
        let t = "mail \(emailA)"
        let c = "again \(emailA) and \(emailB)"
        let n = "note \(emailA)"
        // all on, one token space
        let all = SummaryPipeline.redactTogether(transcript: t, notes: n, context: c, redaction: true)
        let tokens = Set(
            Self.emailTokens(in: all.transcript.text) + Self.emailTokens(in: all.notes!)
                + Self.emailTokens(in: all.context!))
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(
            Self.emailTokens(in: all.transcript.text).first, Self.emailTokens(in: all.context!).first)
        XCTAssertFalse(all.context!.contains("\u{1E}"), "the separator never leaks")
        XCTAssertFalse(all.notes!.contains("\u{1E}"))
        XCTAssertFalse(all.transcript.text.contains("\u{1E}"))
        // group switch off: the context as written, the rest redacted
        let off = SummaryPipeline.redactTogether(
            transcript: t, notes: n, context: c, redaction: true, redactContext: false)
        XCTAssertEqual(off.context, c)
        XCTAssertFalse(off.transcript.text.contains(emailA))
        XCTAssertFalse(off.notes!.contains(emailA))
        // global off: nothing redacted whatever the group says
        for group in [true, false] {
            let none = SummaryPipeline.redactTogether(
                transcript: t, notes: n, context: c, redaction: false, redactContext: group)
            XCTAssertEqual(none.transcript.text, t)
            XCTAssertEqual(none.notes, n)
            XCTAssertEqual(none.context, c)
            XCTAssertTrue(none.transcript.tokens.isEmpty)
        }
        // no context at all
        XCTAssertNil(SummaryPipeline.redactTogether(transcript: t, notes: nil, context: nil, redaction: true).context)
        XCTAssertNil(
            SummaryPipeline.redactTogether(transcript: t, notes: nil, context: "  \n ", redaction: true).context)
    }

    func testATokenShapedStringInAPastReportIsNotRestoredToThisRunsValue() async throws {
        // M5.2 review #2: the outcome is checked. This run's transcript has an email, so
        // <EMAIL_1> is this run's token for it. A past report that happens to contain
        // "<EMAIL_1>" must not become that email, even when the model copies the context.
        try addRecording(
            "meeting_past", hoursAgo: 5,
            report: simpleReport(topic: "TopicPast", text: "Reach <EMAIL_1> before the budget review"))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        let b = copyingBackend()
        let outcome = try await run(b, context: context, transcript: emailTranscript)
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        let cut = try XCTUnwrap(sections.range(of: SummaryPipeline.contextHeading))
        XCTAssertTrue(sections[..<cut.lowerBound].contains("<EMAIL_1>"), "this run's token is in the transcript")
        XCTAssertFalse(sections[cut.upperBound...].contains("<EMAIL_1>"), "the past report's look-alike is taken out")
        XCTAssertTrue(sections[cut.upperBound...].contains("before the budget review"), "the rest stays")
        let written = items(outcome.report, "summary").compactMap(\.text).joined(separator: "\n")
        XCTAssertTrue(written.contains("before the budget review"), "the model did copy the context: \(written)")
        XCTAssertFalse(
            modelText(outcome.report).contains(emailA), "this transcript's address is not in what the model wrote")
    }

    // M5.2 review #1: loose token shapes in a past report are taken out too.
    func testLooseTokenShapesInAPastReportNeverReachTheContextOrGetRestoredToThisRunsValues() async throws {
        let phone = "+1 415 555 0100"
        try addRecording(
            "meeting_past", hoursAgo: 5,
            report: simpleReport(
                topic: "TopicPast", text: "Call EMAIL_1 or <email-1> or < PHONE 2 > or PHONE_1 about the budget plan"))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        for shape in ["EMAIL_1", "<email-1>", "< PHONE 2 >", "PHONE_1"] {
            XCTAssertFalse(context.text.contains(shape), "\(shape) in the built context")
        }
        let transcript = "[00:00:05] You: write to \(emailA) or call \(phone) today.\n[00:00:09] Speaker 1: ok"
        let b = copyingBackend()
        let outcome = try await run(b, context: context, transcript: transcript)
        let sections = try XCTUnwrap(b.calls(.normal).first).input
        let cut = try XCTUnwrap(sections.range(of: SummaryPipeline.contextHeading))
        XCTAssertTrue(sections[..<cut.lowerBound].contains("<EMAIL_1>"), "this run redacted its email")
        XCTAssertTrue(sections[..<cut.lowerBound].contains("<PHONE_"), "and its phone: \(sections)")
        let after = String(sections[cut.upperBound...])
        let loose = try NSRegularExpression(pattern: "(?i)(email|phone)[ _-]?\\d")
        XCTAssertEqual(
            loose.numberOfMatches(in: after, range: NSRange(location: 0, length: (after as NSString).length)), 0, after)
        XCTAssertTrue(after.contains("about the budget plan"))
        let text = modelText(outcome.report)
        XCTAssertTrue(text.contains("about the budget plan"), "the model copied the cleaned context: \(text)")
        XCTAssertFalse(text.contains(emailA), "no address from this transcript came back through the context")
        XCTAssertFalse(text.contains("415 555 0100"))
    }

    /// Everything the model wrote in a report: sections and notices, not the transcript (which is the user's own text).
    private func modelText(_ r: Report) -> String {
        (r.sections.flatMap { $0.items.flatMap { [$0.text, $0.detail, $0.answer, $0.owner, $0.due] } }.compactMap { $0 }
            + r.notices + [r.topic]).joined(separator: "\n")
    }

    /// Writes the first item line it finds after the context heading into its sections reply: a
    /// model that copies the context.
    private func copyingBackend() -> ScriptedBackend {
        var copied = "A summary."  // the review step keeps what the sections step wrote
        return ScriptedBackend(onComplete: { call in
            if let h = call.input.range(of: SummaryPipeline.contextHeading),
                let line = call.input[h.upperBound...].components(separatedBy: "\n").first(where: { $0.hasPrefix("- ") }
                )
            {
                copied = String(line.dropFirst(2))
            }
            switch call.tier {
            case .cheap: return Replies.classify("meeting")
            case .normal: return Replies.sections(["summary": [copied]])
            case .frontier: return Replies.review(["summary": [copied]])
            }
        })
    }

    // MARK: pinned scenario

    func testAPinnedScenarioSkipsTheClassifierAndTheFlagBeatsThePin() async throws {
        try addRecording("meeting_past", hoursAgo: 5, report: simpleReport(topic: "TopicPast"))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        let g = try makeGroup([recName, "meeting_past"])
        try GroupStore.setScenario(g.id, "therapy", catalog: .builtIn, in: dir)

        let pinned = ReportInputs.gather(base: base, catalog: .builtIn)
        let b = echoBackend()
        let outcome = try await run(b, context: pinned.context, forced: pinned.scenario)
        XCTAssertEqual(b.calls(.cheap).count, 0, "no classifier call")
        XCTAssertEqual(outcome.report.scenario, "therapy")

        let flagged = ReportInputs.gather(base: base, catalog: .builtIn, flagScenario: "lecture")
        let b2 = echoBackend()
        let outcome2 = try await run(b2, context: flagged.context, forced: flagged.scenario)
        XCTAssertEqual(b2.calls(.cheap).count, 0)
        XCTAssertEqual(outcome2.report.scenario, "lecture")
    }

    func testWithoutAPinTheClassifierRuns() async throws {
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName])
        let inputs = ReportInputs.gather(base: base, catalog: .builtIn)
        XCTAssertNil(inputs.scenario)
        let b = echoBackend()
        _ = try await run(b, context: inputs.context, forced: inputs.scenario)
        XCTAssertEqual(b.calls(.cheap).count, 1)
    }

    func testAnUnknownPinFallsBackToTheClassifierAndTheNoticeIsAddedByTheCaller() async throws {
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        let g = try makeGroup([recName])
        try GroupStore.change(in: dir) { $0[$0.firstIndex { $0.id == g.id }!].scenario = "gone_scenario" }
        let inputs = ReportInputs.gather(base: base, catalog: .builtIn)
        let b = echoBackend()
        var outcome = try await run(b, context: inputs.context, forced: inputs.scenario)
        outcome.report.notices += inputs.notices
        XCTAssertEqual(b.calls(.cheap).count, 1, "classified")
        XCTAssertTrue(outcome.report.notices.joined().contains("gone_scenario"))
    }

    // MARK: a pipeline failure doesn't lose the context notice

    func testAFailedReviewStillNamesTheGroupInTheNotices() async throws {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "TopicA"))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_a"])
        let b = echoBackend()
        let inner = b.onComplete
        b.onComplete = { call in
            if call.tier == .frontier { throw StepFailure() }
            return try inner(call)
        }
        let outcome = try await run(b, context: GroupContextBuilder.build(for: base))
        XCTAssertFalse(outcome.report.reviewed)
        XCTAssertTrue(outcome.report.notices.joined().contains("\"TopicA\""))
    }
}
