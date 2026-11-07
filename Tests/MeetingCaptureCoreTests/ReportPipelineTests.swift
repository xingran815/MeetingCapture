import XCTest

@testable import MeetingCaptureCore

/// Spec 04's pipeline, answered in process so each test takes milliseconds. The same
/// scenarios run through fake CLIs in `ReportCLITests`.
final class ReportPipelineTests: XCTestCase {

    private func run(
        _ backend: SummaryBackend, transcript: String, forced: String? = nil, redaction: Bool = true,
        catalog: ScenarioCatalog = .builtIn
    ) async throws -> SummaryOutcome {
        try await ReportFixtures.pipeline(backend, redaction: redaction, catalog: catalog)
            .run(transcript: transcript, forcedScenario: forced)
    }

    private let shortTranscript = "[00:00:05] You: Hello there.\n[00:00:09] Speaker 1: Hi, let's begin."

    /// A backend whose three steps answer from closures, so a test changes one step.
    private func backend(
        classify: String = Replies.classify("meeting"), sections: String = Replies.sections(["summary": ["s"]]),
        review: String = Replies.review(["summary": ["s"]]), concepts: String? = nil
    ) -> ScriptedBackend {
        ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return classify
                case .normal: return sections
                case .frontier: return review
                }
            }, onSearch: { _ in concepts })
    }

    // MARK: Six scenarios, recorded replies, committed snapshots

    private func checkScenario(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let backend = try ScriptedBackend.fixture(name)
        let transcript = try ReportFixtures.read(name, "transcript.txt")
        let outcome = try await run(backend, transcript: transcript)
        let report = outcome.report
        XCTAssertEqual(report.scenario, name, file: file, line: line)
        XCTAssertTrue(report.reviewed, "\(report.notices)", file: file, line: line)
        XCTAssertEqual(outcome.flaggedTokens, [], file: file, line: line)
        XCTAssertEqual(report.createdAt, "2027-01-15T08:00:00Z", file: file, line: line)
        let template = try XCTUnwrap(ScenarioCatalog.builtIn.template(named: name))
        XCTAssertEqual(
            report.sections.map(\.id), template.sections.map(\.id), "every section of the template is there",
            file: file, line: line)
        XCTAssertGreaterThan(
            report.sections.filter { !$0.items.isEmpty }.count, report.sections.count - 2, file: file, line: line)
        XCTAssertEqual(backend.searches.count, template.conceptSection == nil ? 0 : 1, file: file, line: line)
        XCTAssertEqual(report.transcript.count, transcript.split(separator: "\n").count, file: file, line: line)

        try ReportFixtures.assertSnapshot(
            ReportRenderer.html(report), scenario: name, file: "expected.html", testFile: file, line: line)
        try ReportFixtures.assertSnapshot(
            ReportRenderer.markdown(report), scenario: name, file: "expected.md", testFile: file, line: line)
    }

    func testMeetingRendersFromRecordedReplies() async throws { try await checkScenario("meeting") }
    func testTherapyRendersFromRecordedReplies() async throws { try await checkScenario("therapy") }
    func testInterviewRendersFromRecordedReplies() async throws { try await checkScenario("interview") }
    func testOneOnOneRendersFromRecordedReplies() async throws { try await checkScenario("one_on_one") }
    func testLectureRendersFromRecordedReplies() async throws { try await checkScenario("lecture") }
    func testGeneralRendersFromRecordedReplies() async throws { try await checkScenario("general") }

    func testTheMeetingReportHasRestoredValuesAndKeepsTheUnsureItem() async throws {
        let outcome = try await run(
            try ScriptedBackend.fixture("meeting"), transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        let text = allText(outcome.report)
        XCTAssertTrue(text.contains("nadia.okafor@example.com"), "the token came back as the value")
        XCTAssertFalse(text.contains("<EMAIL_1>"))
        XCTAssertTrue(
            outcome.report.notices.contains { $0.contains("formatted value(s) were kept out of every request") })
        XCTAssertTrue(items(outcome.report, "actions").contains { $0.isUnsure && !($0.reason ?? "").isEmpty })
        XCTAssertEqual(outcome.report.reviewChanges.count, 2)
        XCTAssertEqual(outcome.report.models.cheap, "Claude haiku")
        XCTAssertEqual(outcome.report.models.normal, "Claude sonnet")
        XCTAssertEqual(outcome.report.models.frontier, "Claude opus")
        XCTAssertEqual(outcome.report.durationSeconds, 281, "the last line starts at 00:04:41")
    }

    func testTherapySourcesComeFromTheSearchAndUnsafeLinksAreDropped() async throws {
        let outcome = try await run(
            try ScriptedBackend.fixture("therapy"), transcript: try ReportFixtures.read("therapy", "transcript.txt"))
        let defusion = try XCTUnwrap(items(outcome.report, "concepts").first { $0.text == "cognitive defusion" })
        XCTAssertEqual(
            defusion.sources?.map(\.url),
            ["https://example.org/act/cognitive-defusion", "https://example.org/act/defusion-sheet.pdf"])
        XCTAssertFalse(allText(outcome.report).contains("javascript:"), "a javascript: source never reaches the report")
        XCTAssertEqual(defusion.detail?.isEmpty, false, "the reviewer's detail is kept")
        let notes = items(outcome.report, "insights")
        XCTAssertTrue(notes.allSatisfy(\.isAI), "insights are marked as the AI's")
        XCTAssertTrue(
            outcome.report.sections.first { $0.id == "insights" }?.note?.contains("not clinical advice") == true)
    }

    func testTranscriptSuggestionsKeepTheOriginalLine() async throws {
        let outcome = try await run(
            try ScriptedBackend.fixture("lecture"), transcript: try ReportFixtures.read("lecture", "transcript.txt"))
        let line = outcome.report.transcript[8]
        XCTAssertTrue(line.text.contains("Atom"), "what was heard stays as it was")
        XCTAssertEqual(line.suggestion, "Is momentum the same as Adam?")
        XCTAssertEqual(outcome.report.transcript.filter { $0.suggestion != nil }.count, 1)
    }

    // MARK: Malformed replies: one retry, then a clear failure

    func testAMalformedSectionsReplyGetsExactlyOneRetry() async throws {
        var normalCalls = 0
        let b = ScriptedBackend(onComplete: { call in
            switch call.tier {
            case .cheap: return Replies.classify("meeting")
            case .normal:
                normalCalls += 1
                return normalCalls == 1 ? "Sorry, I can't produce that." : Replies.sections(["summary": ["fine"]])
            case .frontier: return Replies.review(["summary": ["fine"]])
            }
        })
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertEqual(b.calls(.normal).count, 2)
        XCTAssertFalse(b.calls(.normal)[0].input.contains("wasn't valid JSON"))
        XCTAssertTrue(b.calls(.normal)[1].input.contains("wasn't valid JSON"), "the retry says what went wrong")
        XCTAssertTrue(
            b.calls(.normal)[1].input.hasPrefix(b.calls(.normal)[0].input), "and still carries the transcript")
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "fine")
    }

    func testTwoMalformedSectionsRepliesThrowMalformedReplyAndMakeNoReview() async throws {
        let b = ScriptedBackend(onComplete: { call in
            call.tier == .cheap ? Replies.classify("meeting") : "not json at all"
        })
        do {
            _ = try await run(b, transcript: shortTranscript)
            XCTFail("expected a failure")
        } catch let error as ReportError {
            XCTAssertEqual(error, .malformedReply(step: "sections"))
            XCTAssertTrue(error.localizedDescription.contains("sections"))
            XCTAssertTrue(error.localizedDescription.contains("twice"))
        }
        XCTAssertEqual(b.calls(.normal).count, 2, "one try and one retry, no more")
        XCTAssertEqual(b.calls(.frontier).count, 0, "nothing is reviewed that doesn't exist")
    }

    func testRepliesThatAreJSONButNotTheRequestedShapeCountAsMalformed() async throws {
        for bad in [
            #"{"topic":"x"}"#, #"{"sections":[]}"#, #"{"sections":{"unrelated":[]}}"#,
            #"{"sections":{"summary":"a string, not a list"}}"#, #"{"sections":{"summary":["a bare string"]}}"#,
            "[]", "",
        ] {
            let b = backend(sections: bad)
            do {
                _ = try await run(b, transcript: shortTranscript)
                XCTFail("accepted: \(bad)")
            } catch let error as ReportError {
                XCTAssertEqual(error, .malformedReply(step: "sections"), bad)
            }
            XCTAssertEqual(b.calls(.normal).count, 2, bad)
        }
    }

    func testJSONInsideAFenceOrAfterChatterIsStillRead() async throws {
        let json = Replies.sections(["summary": ["from a fence"]])
        for wrapped in ["```json\n\(json)\n```", "Here is the report you asked for:\n\(json)\nHope that helps."] {
            let b = backend(sections: wrapped, review: wrapped)
            let outcome = try await run(b, transcript: shortTranscript)
            XCTAssertEqual(b.calls(.normal).count, 1, "no retry for a reply that can be read")
            XCTAssertEqual(items(outcome.report, "summary").first?.text, "from a fence")
        }
    }

    func testAMalformedReviewIsRetriedOnceThenTheDraftShipsMarkedUnreviewed() async throws {
        let b = backend(sections: Replies.sections(["summary": ["the draft"]]), review: "garbage")
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertEqual(b.calls(.frontier).count, 2)
        XCTAssertFalse(outcome.report.reviewed)
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "the draft")
        XCTAssertTrue(outcome.report.notices.first?.contains("wasn't reviewed") == true, "the warning comes first")
    }

    func testAMalformedClassifierIsNotRetriedAndFallsBackToGeneral() async throws {
        let b = backend(classify: "I think it is a meeting")
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertEqual(b.calls(.cheap).count, 1, "the cheap step degrades; it is not worth a second call")
        XCTAssertEqual(outcome.report.scenario, "general")
        XCTAssertTrue(outcome.report.notices.joined().contains("couldn't be classified"))
    }

    func testACallThatFailsOutrightIsNotRetried() async throws {
        let b = ScriptedBackend(onComplete: { call in
            if call.tier == .normal { throw CLIError.failed(.claude, "boom") }
            return Replies.classify("meeting")
        })
        do {
            _ = try await run(b, transcript: shortTranscript)
            XCTFail("expected a failure")
        } catch let error as CLIError {
            XCTAssertEqual(error, .failed(.claude, "boom"))
        }
        XCTAssertEqual(b.calls(.normal).count, 1)
    }

    // MARK: Degrades

    func testUnsureOrUnknownClassificationUsesGeneralAndSaysWhy() async throws {
        let cases = [
            Replies.classify("therapy", confidence: "unsure"), Replies.classify("podcast"),
            Replies.classify(""), #"{"confidence":"sure"}"#,
        ]
        for classify in cases {
            let outcome = try await run(backend(classify: classify), transcript: shortTranscript)
            XCTAssertEqual(outcome.report.scenario, "general", classify)
            XCTAssertTrue(outcome.report.notices.joined().contains("general template was used"), classify)
        }
        let unsure = try await run(
            backend(classify: Replies.classify("therapy", confidence: "unsure")), transcript: shortTranscript)
        XCTAssertTrue(unsure.report.notices.joined().contains("best guess: therapy"), "the guess is shown")
    }

    func testAClassifierThatThrowsFallsBackToGeneralWithANotice() async throws {
        let b = ScriptedBackend(onComplete: { call in
            if call.tier == .cheap { throw StepFailure() }
            return call.tier == .normal ? Replies.sections(["summary": ["s"]]) : Replies.review(["summary": ["s"]])
        })
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertEqual(outcome.report.scenario, "general")
        XCTAssertTrue(outcome.report.notices.joined().contains("the step failed on purpose"))
        XCTAssertTrue(outcome.report.reviewed, "only the classify step degraded")
    }

    func testAConfidentClassificationIsCaseInsensitive() async throws {
        let outcome = try await run(
            backend(classify: Replies.classify("Therapy", confidence: "Sure"), concepts: Replies.concepts([])),
            transcript: shortTranscript)
        XCTAssertEqual(outcome.report.scenario, "therapy")
    }

    func testTopicComesFromTheClassifierThenTheSectionsThenTheTemplate() async throws {
        let fromClassify = try await run(
            backend(classify: Replies.classify("meeting", topic: "From classify")), transcript: shortTranscript)
        XCTAssertEqual(fromClassify.report.topic, "From classify")
        let fromSections = try await run(
            backend(
                classify: Replies.classify("meeting", topic: ""),
                sections: Replies.sections(topic: "From sections", ["summary": ["s"]])),
            transcript: shortTranscript)
        XCTAssertEqual(fromSections.report.topic, "From sections")
        let neither = try await run(
            backend(
                classify: Replies.classify("meeting", topic: ""),
                sections: Replies.sections(topic: "", ["summary": ["s"]])),
            transcript: shortTranscript)
        XCTAssertEqual(neither.report.topic, "Company meeting")
    }

    func testAConceptSearchThatFailsLeavesNoSourcesAndASingleNotice() async throws {
        let b = ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("therapy")
                case .normal: return Replies.sections(["summary": ["s"], "concepts": ["cognitive defusion"]])
                case .frontier: return Replies.review(["summary": ["s"], "concepts": ["cognitive defusion"]])
                }
            }, onSearch: { _ in throw StepFailure() })
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertTrue(outcome.report.reviewed, "the review still ran")
        XCTAssertEqual(items(outcome.report, "concepts").count, 1, "the concept stays, without sources")
        XCTAssertNil(items(outcome.report, "concepts").first?.sources)
        XCTAssertEqual(outcome.report.notices.filter { $0.contains("concept search failed") }.count, 1)
        XCTAssertTrue(ReportRenderer.html(outcome.report).contains("None found."))
    }

    func testAConceptSearchWithNothingUsableSaysSo() async throws {
        for reply in ["not json", Replies.json(["concepts": []]), #"{"other":1}"#] {
            let b = ScriptedBackend(
                onComplete: { call in
                    switch call.tier {
                    case .cheap: return Replies.classify("lecture")
                    case .normal: return Replies.sections(["summary": ["s"], "explanations": ["gradient descent"]])
                    case .frontier: return Replies.review(["summary": ["s"], "explanations": ["gradient descent"]])
                    }
                }, onSearch: { _ in reply })
            let outcome = try await run(b, transcript: shortTranscript)
            XCTAssertTrue(outcome.report.notices.joined().contains("gave nothing usable"), reply)
            XCTAssertNil(items(outcome.report, "explanations").first?.sources, reply)
        }
    }

    func testABackendThatCannotSearchSaysSoAndStillMakesTheReport() async throws {
        let b = ScriptedBackend(onComplete: { call in
            switch call.tier {
            case .cheap: return Replies.classify("lecture")
            case .normal: return Replies.sections(["summary": ["s"], "explanations": ["gradient descent"]])
            case .frontier: return Replies.review(["summary": ["s"], "explanations": ["gradient descent"]])
            }
        })
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertTrue(outcome.report.notices.joined().contains("need a subscription CLI"))
        XCTAssertTrue(outcome.report.reviewed)
        XCTAssertEqual(b.searches.count, 1)
    }

    func testAFailedReviewShipsTheDraftWithABannerInHTMLAndMarkdown() async throws {
        let backend = try ScriptedBackend.fixture("meeting", failing: .frontier)
        let outcome = try await run(backend, transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        let report = outcome.report
        XCTAssertFalse(report.reviewed)
        XCTAssertEqual(report.models.frontier, "")
        XCTAssertTrue(report.reviewChanges.isEmpty)
        // The draft's content, not the review's.
        let draftActions = items(report, "actions")
        XCTAssertEqual(draftActions.count, 4)
        XCTAssertFalse(draftActions.contains { $0.isUnsure }, "the review is what marked the Friday action unsure")
        XCTAssertTrue(report.notices.first?.contains("wasn't reviewed by the frontier model") == true)
        let html = ReportRenderer.html(report)
        XCTAssertTrue(html.contains("class=\"banner\""))
        XCTAssertTrue(html.contains("Not reviewed."))
        XCTAssertTrue(ReportRenderer.markdown(report).contains("**Not reviewed.**"))
        XCTAssertTrue(ReportRenderer.terminalSummary(report).contains("NOT REVIEWED"))
        let reviewed = try await run(
            try ScriptedBackend.fixture("meeting"), transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        XCTAssertFalse(
            ReportRenderer.html(reviewed.report).contains("class=\"banner\""), "no banner when it was reviewed")
    }

    func testSourcesAreOnlyEverTheSearchsNotTheReviewers() async throws {
        // The reviewer renames one concept; its sources are gone, and no URL it invents is kept.
        let reviewObject: [String: Any] = [
            "topic": "t",
            "sections": [
                "concepts": [
                    Replies.item("Cognitive Defusion", detail: "see https://invented.example.net/x"),
                    Replies.item("A concept the reviewer added"),
                ]
            ],
            "changes": [], "transcriptSuggestions": [],
        ]
        let b = ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("therapy")
                case .normal: return Replies.sections(["concepts": ["cognitive defusion"]])
                case .frontier: return Replies.json(reviewObject)
                }
            },
            onSearch: { _ in
                Replies.concepts([("cognitive defusion", "x", [("Real", "https://example.org/real")])])
            })
        let outcome = try await run(b, transcript: shortTranscript)
        let concepts = items(outcome.report, "concepts")
        XCTAssertEqual(concepts.first?.sources?.map(\.url), ["https://example.org/real"], "matched case-insensitively")
        XCTAssertNil(concepts.last?.sources)
    }

    func testReviewAndConceptSearchCanBeSwitchedOff() async throws {
        let b = try ScriptedBackend.fixture("therapy")
        var p = ReportFixtures.pipeline(b)
        p.review = false
        p.searchConcepts = false
        let outcome = try await p.run(
            transcript: try ReportFixtures.read("therapy", "transcript.txt"), forcedScenario: "therapy")
        XCTAssertEqual(b.calls.count, 1, "sections only")
        XCTAssertEqual(b.searches.count, 0)
        XCTAssertFalse(outcome.report.reviewed)
        XCTAssertTrue(outcome.report.notices.first?.contains("switched off") == true)
    }

    // MARK: Forced scenario, empty input, caps

    func testAForcedScenarioSkipsTheClassifierAndIsCaseInsensitive() async throws {
        let b = backend(concepts: Replies.concepts([]))
        let outcome = try await run(b, transcript: shortTranscript, forced: "Therapy")
        XCTAssertEqual(outcome.report.scenario, "therapy")
        XCTAssertEqual(b.calls(.cheap).count, 0)
        XCTAssertEqual(outcome.report.models.cheap, "")
    }

    func testAnUnknownForcedScenarioNamesTheKnownOnesAndSendsNothing() async throws {
        let b = backend()
        do {
            _ = try await run(b, transcript: shortTranscript, forced: "podcast")
            XCTFail("expected a failure")
        } catch let error as ReportError {
            guard case .unknownScenario(let name, let known) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "podcast")
            XCTAssertEqual(Set(known), Set(ReportFixtures.scenarios))
            XCTAssertTrue(error.localizedDescription.contains("one_on_one"))
        }
        XCTAssertEqual(b.calls.count, 0)
    }

    func testAnEmptyOrBlankTranscriptStopsBeforeAnyCall() async throws {
        let b = backend()
        for text in ["", "  \n\t \n"] {
            do {
                _ = try await run(b, transcript: text)
                XCTFail("expected a failure")
            } catch let error as ReportError {
                XCTAssertEqual(error, .emptyTranscript)
            }
        }
        XCTAssertEqual(b.calls.count, 0)
    }

    func testRunawayModelOutputIsCut() async throws {
        let many = (0..<80).map { Replies.item("item \($0)") }
        let long = Replies.item(String(repeating: "x", count: 7000))
        let sections = Replies.sectionsItems(["summary": [long], "who_said_what": many])
        let outcome = try await run(backend(sections: sections, review: sections), transcript: shortTranscript)
        XCTAssertEqual(items(outcome.report, "who_said_what").count, SummaryPipeline.maxItemsPerSection)
        let text = try XCTUnwrap(items(outcome.report, "summary").first?.text)
        XCTAssertEqual(text.count, SummaryPipeline.maxFieldLength + 1, "cut at the limit, with an ellipsis")
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testEmptyItemsAreDroppedUnknownSectionsIgnoredAndMissingOnesEmpty() async throws {
        let sections = Replies.sectionsItems([
            "summary": [Replies.item("kept"), Replies.item("")],
            "not_a_section": [Replies.item("ignored")],
        ])
        let outcome = try await run(backend(sections: sections, review: sections), transcript: shortTranscript)
        XCTAssertEqual(items(outcome.report, "summary").count, 1)
        XCTAssertEqual(outcome.report.sections.count, 5, "the template's sections, no more and no fewer")
        XCTAssertTrue(items(outcome.report, "actions").isEmpty)
        XCTAssertFalse(allText(outcome.report).contains("ignored"))
    }

    func testInsightsAreAlwaysMarkedAsTheAIsEvenIfTheModelSaysOtherwise() async throws {
        let sections = Replies.sectionsItems(["insights": [Replies.item("try this", source: "transcript")]])
        let outcome = try await run(backend(sections: sections, review: sections), transcript: shortTranscript)
        XCTAssertEqual(items(outcome.report, "insights").first?.source, "ai")
    }

    func testALanguageThatIsNotALanguageCodeIsDropped() async throws {
        for (given, kept) in [("en", "en"), ("zh-CN", "zh-CN"), ("\"><script>", ""), ("english please", ""), ("", "")] {
            let outcome = try await run(
                backend(classify: Replies.classify("meeting", language: given)), transcript: shortTranscript)
            XCTAssertEqual(outcome.report.language, kept, given)
        }
    }

    func testTheClassifierSampleIsTheHeadPlusLinesFromTheMiddleAndEnd() {
        let short = String(repeating: "a", count: 5000)
        XCTAssertEqual(SummaryPipeline.classifierSample(short), short, "under 6000 characters it is all there is")
        let text = (0..<200).map { "line \($0) " + String(repeating: "w", count: 40) }.joined(separator: "\n")
        let sample = SummaryPipeline.classifierSample(text)
        XCTAssertTrue(sample.contains("line 0 "))
        XCTAssertTrue(sample.contains("line 199 "))
        XCTAssertTrue(sample.contains("line 100 "), "the middle")
        XCTAssertFalse(sample.contains("line 150 "), "between the middle and the end")
        XCTAssertLessThan(sample.count, 6000)
        XCTAssertEqual(
            SummaryPipeline.classifierSample(String(repeating: "b", count: 9000)).count, 6000,
            "a few long lines are just cut")
    }

    // MARK: Redaction round trip

    func testTokensAreRestoredInEveryFieldAModelWrites() async throws {
        let transcript = "[00:00:01] You: Mail priya@example.com now."
        let t = "<EMAIL_1>"
        let item = Replies.item(
            "t \(t)", speaker: "s \(t)", owner: "o \(t)", due: "d \(t)", answer: "a \(t)", quote: "q \(t)",
            detail: "de \(t)", confidence: "unsure", reason: "r \(t)")
        let sections = Replies.sectionsItems(topic: "topic \(t)", ["summary": [item], "actions": [item]])
        let review = Replies.sectionsItems(
            topic: "topic \(t)", ["summary": [item], "actions": [item]], changes: [("what \(t)", "why \(t)")],
            suggestions: [(0, "Mail \(t) now.")])
        let outcome = try await run(
            backend(classify: Replies.classify("meeting", topic: "classify \(t)"), sections: sections, review: review),
            transcript: transcript)
        let report = outcome.report
        let email = "priya@example.com"
        XCTAssertEqual(report.topic, "classify \(email)")
        let first = try XCTUnwrap(items(report, "actions").first)
        for field in [
            first.text, first.speaker, first.owner, first.due, first.answer, first.quote, first.detail, first.reason,
        ] {
            XCTAssertTrue(field?.contains(email) == true, "\(field ?? "nil")")
        }
        XCTAssertEqual(report.reviewChanges, [Report.Change(what: "what \(email)", why: "why \(email)")])
        XCTAssertEqual(report.transcript[0].suggestion, "Mail \(email) now.")
        XCTAssertEqual(report.transcript[0].text, "Mail \(email) now.", "the transcript is the original text")
        XCTAssertFalse(allText(report).contains(t))
        XCTAssertEqual(outcome.flaggedTokens, [])
        XCTAssertFalse(report.notices.joined().contains("Couldn't restore"))
    }

    func testAnUnknownTokenIsLeftAloneAndFlaggedInTheNotices() async throws {
        let sections = Replies.sections(["summary": ["Call <PHONE_9> or <EMAIL_1>."]])
        let b = backend(sections: sections, review: sections)
        let outcome = try await run(b, transcript: "[00:00:01] You: Mail priya@example.com")
        XCTAssertEqual(outcome.flaggedTokens, ["<PHONE_9>"])
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "Call <PHONE_9> or priya@example.com.")
        let note = try XCTUnwrap(outcome.report.notices.first { $0.contains("Couldn't restore") })
        XCTAssertTrue(note.contains("<PHONE_9>"))
    }

    func testNoFormattedValueReachesAnyStepAndTheTokenInstructionIsOnEveryStep() async throws {
        let email = "priya" + "@example.com"
        let transcript = "[00:00:01] You: Mail \(email) about the budget.\n[00:00:09] Speaker 1: Will do."
        let sections = Replies.sections(["summary": ["<EMAIL_1>"], "concepts": ["cognitive defusion"]])
        let b = ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("therapy")
                case .normal: return sections
                case .frontier: return Replies.review(["summary": ["<EMAIL_1>"], "concepts": ["cognitive defusion"]])
                }
            }, onSearch: { _ in Replies.concepts([]) })
        _ = try await run(b, transcript: transcript)
        XCTAssertEqual(b.calls.count, 3)
        for call in b.calls {
            XCTAssertFalse((call.system + call.input).contains(email))
            XCTAssertTrue(call.system.contains("placeholder tokens"), "every step is told about tokens")
        }
        XCTAssertEqual(b.searches, [["cognitive defusion"]])
    }

    func testWithRedactionOffTheTextGoesAsItIsAndNothingIsRestored() async throws {
        let email = "priya" + "@example.com"
        let sections = Replies.sections(["summary": ["See <EMAIL_1>"]])
        let b = backend(sections: sections, review: sections)
        let outcome = try await run(b, transcript: "[00:00:01] You: Mail \(email)", redaction: false)
        XCTAssertTrue(b.calls(.normal)[0].input.contains(email))
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "See <EMAIL_1>")
        XCTAssertEqual(outcome.redactedValues, 0)
        XCTAssertFalse(b.calls(.normal)[0].system.contains("placeholder tokens"))
    }

    // MARK: Prompts

    func testTheReviewIsGivenTheNumberedTranscriptAndTheDraft() async throws {
        let b = backend(sections: Replies.sections(["summary": ["the draft text"]]))
        _ = try await run(b, transcript: shortTranscript)
        let review = try XCTUnwrap(b.calls(.frontier).first)
        XCTAssertTrue(review.input.contains("#0 [00:00:05] You: Hello there."))
        XCTAssertTrue(review.input.contains("#1 [00:00:09] Speaker 1: Hi, let's begin."))
        XCTAssertTrue(review.input.contains("the draft text"))
        XCTAssertTrue(review.system.contains("If you aren't sure, say so. If you don't have an answer, say you don't."))
        XCTAssertTrue(
            b.calls(.normal)[0].system.contains(
                "If you aren't sure, say so. If you don't have an answer, say you don't."))
        XCTAssertTrue(review.schema.contains("transcriptSuggestions"))
        XCTAssertFalse(b.calls(.normal)[0].schema.contains("transcriptSuggestions"))
    }

    func testTherapyRulesReachEveryStepOfATherapyRun() async throws {
        let b = backend(classify: Replies.classify("therapy"), concepts: Replies.concepts([]))
        _ = try await run(b, transcript: shortTranscript)
        for call in b.calls where call.tier != .cheap {
            XCTAssertTrue(call.system.contains("Do not diagnose"))
            XCTAssertTrue(call.system.contains("Do not give medical advice"))
            XCTAssertTrue(call.system.contains("Do not take sides"))
        }
        XCTAssertTrue(b.calls(.cheap)[0].system.contains("therapy"), "the classifier is told what each scenario is")
    }

    // MARK: Transcript suggestions

    func testSuggestionsThatChangeNothingOrPointNowhereAreIgnored() async throws {
        let review = Replies.review(
            ["summary": ["s"]],
            suggestions: [(0, "Hello there."), (1, "Hi, let's begin properly."), (7, "nowhere"), (-1, "negative")])
        let outcome = try await run(backend(review: review), transcript: shortTranscript)
        XCTAssertNil(outcome.report.transcript[0].suggestion, "the same text is no suggestion")
        XCTAssertEqual(outcome.report.transcript[1].suggestion, "Hi, let's begin properly.")
        XCTAssertEqual(outcome.report.transcript[1].text, "Hi, let's begin.")
    }

    // MARK: Concept search sees names only

    private func therapyBackend(concepts names: [String], capture: @escaping ([String]) -> Void = { _ in })
        -> ScriptedBackend
    {
        ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("therapy")
                case .normal: return Replies.sections(["summary": ["s"], "concepts": names])
                case .frontier: return Replies.review(["summary": ["s"], "concepts": names])
                }
            },
            onSearch: { found in
                capture(found)
                return Replies.concepts(found.map { ($0, "e", []) })
            })
    }

    private let danaTranscript = """
        [00:00:05] Dana: I keep not calling my mother back because we always end up arguing about money.
        [00:00:20] Speaker 1: Let's try cognitive defusion on the thought that you are a bad daughter.
        [00:00:41] Dana: That feels odd but I will try it before Sunday dinner.
        """

    func testTheSearchGetsConceptNamesOnlyAndNotAConceptNamedAfterASpeaker() async throws {
        let b = therapyBackend(concepts: ["cognitive defusion", "Dana's coping plan", "values exercise", "DANA"])
        let outcome = try await run(b, transcript: danaTranscript)
        XCTAssertEqual(b.searches, [["cognitive defusion", "values exercise"]])
        XCTAssertTrue(outcome.report.notices.joined().contains("2 concept name(s) weren't looked up"))
        XCTAssertEqual(
            items(outcome.report, "concepts").count, 4, "the concepts stay in the report; only the lookup is skipped")
        let sent = b.searches.joined().joined(separator: " ").lowercased()
        XCTAssertFalse(sent.contains("dana"))
        for sentence in ["calling my mother", "arguing about money", "bad daughter", "Sunday dinner"] {
            XCTAssertFalse(sent.contains(sentence.lowercased()))
        }
    }

    func testAConceptTooLongOrLikeATranscriptLineIsNotSearched() async throws {
        let names = [
            "cognitive defusion", "I keep not calling my mother back because of money", "Call me at 555 0100",
            "a:b", "mail priya@example.com",
        ]
        let b = therapyBackend(concepts: names)
        _ = try await run(b, transcript: danaTranscript)
        XCTAssertEqual(b.searches, [["cognitive defusion"]])
    }

    func testNoSearchAtAllWhenEveryConceptIsRefused() async throws {
        let b = therapyBackend(concepts: ["Dana's plan"])
        _ = try await run(b, transcript: danaTranscript)
        XCTAssertEqual(b.searches.count, 0, "nothing generic to look up, so nothing goes out")
    }

    func testAtMostEightConceptsAreSearched() async throws {
        let names = (0..<12).map { "concept \(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"][$0])" }
        let b = therapyBackend(concepts: names)
        _ = try await run(b, transcript: danaTranscript)
        XCTAssertEqual(b.searches.first?.count, 8)
    }

    func testWhichConceptNamesAreSearchable() {
        let speakers: Set<String> = ["You", "Speaker 1", "Dana Lee", ""]
        for ok in ["cognitive defusion", "values", "You and me", "Speaker bias", "gradient descent"] {
            XCTAssertTrue(SummaryPipeline.isSearchableConcept(ok, speakers: speakers), ok)
        }
        for bad in [
            "dana", "Lee's method", "DANA LEE", "Dana's approach", "type 2 diabetes",
            "one two three four five six seven", "",
        ] {
            XCTAssertFalse(SummaryPipeline.isSearchableConcept(bad, speakers: speakers), bad)
        }
    }

    /// BUG candidate: a Chinese name inside a longer concept has no spaces around it, so
    /// the word test (split on non-letters, then equality) never matches. The user is
    /// bilingual and the label comes straight from the rename menu.
    func testAConceptContainingAChineseSpeakerNameIsNotSearched() {
        XCTAssertFalse(SummaryPipeline.isSearchableConcept("小雨的应对方法", speakers: ["小雨", "You"]))
        XCTAssertFalse(SummaryPipeline.isSearchableConcept("小雨", speakers: ["小雨"]))
    }

    /// BUG candidate: matching ignores accents, so a speaker `Zoë` doesn't block `Zoe's plan`.
    func testASpeakerNameMatchesWithoutRegardToAccents() {
        XCTAssertFalse(SummaryPipeline.isSearchableConcept("Zoe's plan", speakers: ["Zoë"]))
        XCTAssertFalse(SummaryPipeline.isSearchableConcept("José method", speakers: ["Jose"]))
    }

    // MARK: Inert output through the whole pipeline

    func testHostileTranscriptAndModelTextRenderInertThroughTheWholePipeline() async throws {
        let transcript = """
            [00:00:01] <img src=x onerror=alert(1)>: <script>alert(1)</script> hello
            [00:00:05] You: "><svg onload=alert(2)> and 'quotes' & more
            [00:00:09] You: see javascript:alert(3) and [x](javascript:alert(4)) </script><script>alert(5)</script>
            """
        let bad = XSS.payloads
        let item = Replies.item(
            bad[0], speaker: bad[1], owner: bad[2], due: bad[3], answer: bad[4], quote: bad[5], detail: bad[6],
            confidence: "unsure", reason: bad[7], source: "ai")
        let sections = Replies.sectionsItems(
            topic: bad[8],
            [
                "summary": [item], "who_said_what": [item], "open_questions": [item], "actions": [item],
                "insights": [item],
            ])
        let review = Replies.sectionsItems(
            topic: bad[8],
            [
                "summary": [item], "who_said_what": [item], "open_questions": [item], "actions": [item],
                "insights": [item],
            ],
            changes: [(bad[9], bad[10])], suggestions: [(0, bad[11]), (1, bad[12])])
        let b = backend(
            classify: Replies.classify("meeting", topic: bad[8], language: "\"><script>alert(9)</script>"),
            sections: sections, review: review)
        let outcome = try await run(b, transcript: transcript)
        let html = ReportRenderer.html(outcome.report)
        XSS.assertInert(html)
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; hello"), "shown as text")
        XCTAssertFalse(html.contains("<html lang=\"\"><script"), "a hostile language code is dropped")
        XCTAssertEqual(outcome.report.language, "")
        // Markdown is plain text for other tools, but a link in it is still only ever http(s).
        XCTAssertFalse(ReportRenderer.markdown(outcome.report).lowercased().contains("](javascript:"))
    }

    func testAHostileSourceFromTheSearchIsDroppedBeforeItIsEverStored() async throws {
        let b = ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("therapy")
                case .normal: return Replies.sections(["concepts": ["cognitive defusion"]])
                case .frontier: return Replies.review(["concepts": ["cognitive defusion"]])
                }
            },
            onSearch: { _ in
                Replies.concepts([
                    (
                        "cognitive defusion", "x",
                        XSS.badURLs.map { ("bad", $0) } + [("good", "https://example.org/ok")]
                    )
                ])
            })
        let outcome = try await run(b, transcript: shortTranscript)
        XCTAssertEqual(items(outcome.report, "concepts").first?.sources?.map(\.url), ["https://example.org/ok"])
    }
}
