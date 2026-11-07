import XCTest

@testable import MeetingCaptureCore

/// The report pipeline through the real runner and router, with fake `claude` and `codex`
/// scripts: what a CLI is actually given, in call order. Each test starts several processes,
/// each test takes under a second, so the class is not a SlowTests one (D-77); the same logic runs in process in `ReportPipelineTests`.
final class ReportCLITests: GuardedTestCase {

    private var world: FakeCLIWorld!
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
        dir = world.root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func pipeline(redaction: Bool = true, primary: CLIKind = .claude) -> SummaryPipeline {
        ReportFixtures.pipeline(CLISummaryBackend(router: world.router(primary: primary)), redaction: redaction)
    }

    private func script(_ json: String, cli: CLIKind = .claude) -> FakeCLIWorld.Script {
        FakeCLIWorld.jsonScript(json, cli: cli)
    }

    // MARK: Six scenarios through fake CLIs

    private func checkScenario(
        _ name: String, cli: CLIKind = .claude, file: StaticString = #filePath, line: UInt = #line
    )
        async throws
    {
        try world.installFixture(name, cli: cli)
        let transcript = try ReportFixtures.read(name, "transcript.txt")
        let outcome = try await pipeline(primary: cli).run(transcript: transcript)
        XCTAssertEqual(outcome.report.scenario, name, file: file, line: line)
        XCTAssertTrue(outcome.report.reviewed, "\(outcome.report.notices)", file: file, line: line)

        let calls = world.calls(cli)
        let hasConcepts = ScenarioCatalog.builtIn.template(named: name)?.conceptSection != nil
        XCTAssertEqual(
            calls.count, hasConcepts ? 4 : 3, "classify, sections, [concepts], review", file: file, line: line)
        XCTAssertEqual(calls.filter(\.toolsOn).count, hasConcepts ? 1 : 0, file: file, line: line)

        try ReportFixtures.assertSnapshot(
            ReportRenderer.html(outcome.report), scenario: name, file: "expected.html", testFile: file, line: line)
        try ReportFixtures.assertSnapshot(
            ReportRenderer.markdown(outcome.report), scenario: name, file: "expected.md", testFile: file, line: line)
    }

    func testMeetingOnFakeClaude() async throws { try await checkScenario("meeting") }
    func testTherapyOnFakeClaude() async throws { try await checkScenario("therapy") }
    func testInterviewOnFakeClaude() async throws { try await checkScenario("interview") }
    func testOneOnOneOnFakeClaude() async throws { try await checkScenario("one_on_one") }
    func testLectureOnFakeClaude() async throws { try await checkScenario("lecture") }
    func testGeneralOnFakeClaude() async throws { try await checkScenario("general") }
    func testTherapyOnFakeCodexGivesTheSameReport() async throws {
        // The model label differs ("Codex gpt-6.1-sol"), so compare the content, not the snapshot.
        try world.installFixture("therapy", cli: .codex)
        let codex = try await pipeline(primary: .codex).run(
            transcript: try ReportFixtures.read("therapy", "transcript.txt"))
        let world2 = try FakeCLIWorld()
        defer { world2.cleanUp() }
        try world2.installFixture("therapy", cli: .claude)
        let claude = try await ReportFixtures.pipeline(CLISummaryBackend(router: world2.router())).run(
            transcript: try ReportFixtures.read("therapy", "transcript.txt"))
        XCTAssertEqual(codex.report.sections, claude.report.sections)
        XCTAssertEqual(codex.report.transcript, claude.report.transcript)
        XCTAssertTrue(codex.report.models.normal.hasPrefix("Codex"))
    }

    func testEveryCallCarriesItsJSONSchemaAndTheRightTier() async throws {
        try world.installFixture("meeting")
        _ = try await pipeline().run(transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        let calls = world.calls(.claude)
        func arg(_ call: FakeCLIWorld.Call, _ name: String) -> String {
            call.args[call.args.firstIndex(of: name)! + 1]
        }
        XCTAssertEqual(calls.map { arg($0, "--model") }, ["haiku", "sonnet", "opus"])
        let schemas = calls.map { arg($0, "--json-schema") }
        XCTAssertTrue(schemas[0].contains("\"scenario\"") && schemas[0].contains("one_on_one"))
        XCTAssertTrue(schemas[1].contains("open_questions") && !schemas[1].contains("transcriptSuggestions"))
        XCTAssertTrue(schemas[2].contains("transcriptSuggestions"))
        for call in calls { XCTAssertEqual(arg(call, "--tools"), "", "tools are off for every call with free text") }
    }

    // MARK: Malformed replies

    func testANonJSONSectionsReplyIsRetriedOnceThenSucceeds() async throws {
        let sections = Replies.sections(["summary": ["fine"]])
        try world.install(
            .codex,
            answers: [
                script(Replies.classify("meeting"), cli: .codex),
                .init(stdout: FakeCLIWorld.codexOK("Sorry, I cannot do that.")),
                script(sections, cli: .codex), script(Replies.review(["summary": ["fine"]]), cli: .codex),
            ])
        let outcome = try await pipeline(primary: .codex).run(transcript: "[00:00:01] You: hello")
        let calls = world.calls(.codex)
        XCTAssertEqual(calls.count, 4, "classify, sections, one retry, review")
        XCTAssertTrue(calls[2].stdin.contains("wasn't valid JSON"))
        XCTAssertFalse(calls[1].stdin.contains("wasn't valid JSON"))
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "fine")
    }

    func testTwoNonJSONRepliesFailClearlyAndLeaveTheTranscriptAlone() async throws {
        try world.install(
            .codex,
            answers: [
                script(Replies.classify("meeting"), cli: .codex), .init(stdout: FakeCLIWorld.codexOK("not json")),
                .init(stdout: FakeCLIWorld.codexOK("still not json")),
            ])
        let transcript = "[00:00:01] You: hello"
        let file = dir.appendingPathComponent("meeting.txt")
        try transcript.write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await pipeline(primary: .codex).run(transcript: try String(contentsOf: file, encoding: .utf8))
            XCTFail("expected a failure")
        } catch let error as ReportError {
            XCTAssertEqual(error, .malformedReply(step: "sections"))
            XCTAssertTrue(error.localizedDescription.contains("no report was written"))
        }
        XCTAssertEqual(world.calls(.codex).count, 3, "classify, sections, one retry, and then it stops")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), transcript, "the transcript is still there")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path), ["meeting.txt"], "no half-written report")
    }

    func testAClaudeReplyOfTheWrongShapeIsRetriedOnceToo() async throws {
        let wrong = script(#"{"unexpected":true}"#)
        try world.install(.claude, answers: [script(Replies.classify("meeting")), wrong, wrong])
        do {
            _ = try await pipeline().run(transcript: "[00:00:01] You: hello")
            XCTFail("expected a failure")
        } catch let error as ReportError {
            XCTAssertEqual(error, .malformedReply(step: "sections"))
        }
        XCTAssertEqual(world.calls(.claude).count, 3)
    }

    // MARK: Degrades through the router

    func testAFailedConceptSearchStillGivesAReviewedReportWithANotice() async throws {
        let sections = Replies.sections(["summary": ["s"], "concepts": ["cognitive defusion"]])
        try world.install(
            .claude,
            answers: [
                script(Replies.classify("therapy")), script(sections),
                .init(stdout: "", exit: 1, stderr: "search tool crashed"),
                script(Replies.review(["summary": ["s"], "concepts": ["cognitive defusion"]])),
            ])
        let outcome = try await pipeline().run(transcript: "[00:00:01] You: hello")
        XCTAssertTrue(outcome.report.reviewed)
        XCTAssertTrue(outcome.report.notices.joined().contains("concept search failed"))
        XCTAssertNil(items(outcome.report, "concepts").first?.sources)
        XCTAssertEqual(world.calls(.claude).count, 4)
    }

    func testAFailedReviewShipsTheDraftMarkedNotReviewed() async throws {
        try world.install(
            .claude,
            answers: [
                script(Replies.classify("meeting")), script(Replies.sections(["summary": ["the draft"]])),
                .init(stdout: "", exit: 1, stderr: "model overloaded"),
            ])
        let outcome = try await pipeline().run(transcript: "[00:00:01] You: hello")
        XCTAssertFalse(outcome.report.reviewed)
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "the draft")
        XCTAssertTrue(ReportRenderer.html(outcome.report).contains("Not reviewed."))
        XCTAssertTrue(ReportRenderer.markdown(outcome.report).contains("Not reviewed."))
    }

    func testAFullLimitDuringTheReviewMovesOnlyTheReviewToTheOtherCLI() async throws {
        try world.install(
            .claude,
            answers: [
                script(Replies.classify("meeting")), script(Replies.sections(["summary": ["draft"]])),
                .init(stdout: "", exit: 1, stderr: "usage limit reached"),
            ])
        try world.install(.codex, answers: [script(Replies.review(["summary": ["reviewed"]]), cli: .codex)])
        let outcome = try await pipeline().run(transcript: "[00:00:01] You: hello")
        XCTAssertTrue(outcome.report.reviewed)
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "reviewed")
        XCTAssertTrue(outcome.report.models.cheap.hasPrefix("Claude"))
        XCTAssertTrue(outcome.report.models.frontier.hasPrefix("Codex"))
        XCTAssertTrue(outcome.report.notices.joined().contains("Codex"), "the switch is in the report")
        XCTAssertEqual(world.calls(.codex).count, 1)
    }

    func testBothCLIsFullStopsWithNothingWrittenAndNoNetworkRequest() async throws {
        try world.install(.claude, answers: [.init(stdout: "", exit: 1, stderr: "usage limit reached")])
        try world.install(.codex, answers: [.init(stdout: "", exit: 1, stderr: "usage limit reached")])
        let before = NetworkRefusal.attempts
        do {
            _ = try await pipeline().run(transcript: "[00:00:01] You: hello", forcedScenario: "meeting")
            XCTFail("expected a stop")
        } catch {
            XCTAssertTrue(error is LLMRouter.RouterError, "\(error)")
        }
        XCTAssertEqual(NetworkRefusal.attempts, before)
    }

    // MARK: The concept search sees concept names and nothing else

    private let danaTranscript = """
        [00:00:05] Dana: I keep not calling my mother back because we always end up arguing about money.
        [00:00:20] Speaker 1: Let's try cognitive defusion on the thought that you are a bad daughter, and write to me at coach@example.com.
        [00:00:41] Dana: That feels odd but I will try it before Sunday dinner at the Rosewood Cafe.
        """

    private func assertSearchSawOnlyNames(
        cli: CLIKind, transcript: String, names: [String], skipped: [String], file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sent = names.filter { !skipped.contains($0) }
        try world.install(
            cli,
            answers: [
                script(Replies.classify("therapy"), cli: cli),
                script(Replies.sections(["summary": ["s <EMAIL_1>"], "concepts": names]), cli: cli),
                script(
                    Replies.concepts(
                        sent.map {
                            (
                                $0, "explained",
                                [("Ref", "https://example.org/\($0.replacingOccurrences(of: " ", with: "-"))")]
                            )
                        }), cli: cli),
                script(Replies.review(["summary": ["s <EMAIL_1>"], "concepts": names]), cli: cli),
            ])
        let outcome = try await pipeline(primary: cli).run(transcript: transcript)

        let calls = world.calls(cli)
        XCTAssertEqual(calls.count, 4, file: file, line: line)
        let searches = calls.filter(\.toolsOn)
        XCTAssertEqual(searches.count, 1, "exactly one call has tools on", file: file, line: line)
        let search = try XCTUnwrap(searches.first)
        let everything = search.everything
        for name in sent { XCTAssertTrue(everything.contains(name), name, file: file, line: line) }
        for name in skipped {
            XCTAssertFalse(
                everything.contains(name), "a name that is not generic went out: \(name)", file: file, line: line)
        }
        XCTAssertFalse(everything.lowercased().contains("dana"), "the speaker's name went out", file: file, line: line)
        XCTAssertFalse(everything.contains("example.com"), file: file, line: line)
        XCTAssertFalse(everything.contains("<EMAIL"), file: file, line: line)
        for text in TranscriptParser.parse(transcript).map(\.text) {
            XCTAssertFalse(everything.contains(text), "a transcript line went out: \(text)", file: file, line: line)
            for fragment in ["calling my mother", "arguing about money", "bad daughter", "Sunday dinner", "Rosewood"] {
                XCTAssertFalse(everything.contains(fragment), fragment, file: file, line: line)
            }
        }
        XCTAssertEqual(
            search.stdin,
            "Find a reliable general reference for each concept:\n" + sent.map { "- \($0)" }.joined(separator: "\n"),
            "the input is the fixed sentence and the names", file: file, line: line)
        XCTAssertTrue(
            calls[1].stdin.contains("calling my mother"), "the sections step did see the transcript", file: file,
            line: line)
        XCTAssertFalse(calls[1].toolsOn, file: file, line: line)
        XCTAssertFalse(calls[3].toolsOn, file: file, line: line)
        XCTAssertEqual(items(outcome.report, "concepts").count, names.count, file: file, line: line)
    }

    func testTherapyConceptSearchOnClaudeHasNoTranscriptTextOrNames() async throws {
        try await assertSearchSawOnlyNames(
            cli: .claude, transcript: danaTranscript,
            names: ["cognitive defusion", "Dana's coping plan", "values exercise"], skipped: ["Dana's coping plan"])
    }

    func testTherapyConceptSearchOnCodexHasNoTranscriptTextOrNames() async throws {
        try await assertSearchSawOnlyNames(
            cli: .codex, transcript: danaTranscript,
            names: ["cognitive defusion", "Dana's coping plan", "values exercise"], skipped: ["Dana's coping plan"])
    }

    func testLectureConceptSearchHasNoTranscriptTextOrNames() async throws {
        let lecture = """
            [00:00:05] Dana: I keep not calling my mother back because we always end up arguing about money.
            [00:00:20] Speaker 1: Gradient descent steps downhill, and the bad daughter example is on the slide; write to coach@example.com.
            [00:00:41] Dana: That feels odd but I will try it before Sunday dinner at the Rosewood Cafe.
            """
        try world.install(
            .claude,
            answers: [
                script(Replies.classify("lecture")),
                script(
                    Replies.sections(["summary": ["s"], "explanations": ["gradient descent", "Dana", "learning rate"]])),
                script(Replies.concepts([("gradient descent", "e", []), ("learning rate", "e", [])])),
                script(
                    Replies.review(["summary": ["s"], "explanations": ["gradient descent", "Dana", "learning rate"]])),
            ])
        _ = try await pipeline().run(transcript: lecture)
        let search = try XCTUnwrap(world.calls(.claude).first { $0.toolsOn })
        XCTAssertEqual(
            search.stdin, "Find a reliable general reference for each concept:\n- gradient descent\n- learning rate")
        XCTAssertFalse(search.everything.contains("Dana"))
        XCTAssertFalse(search.everything.contains("daughter"))
    }

    func testNoToolsOnCallEverCarriesATranscriptWhateverTheScenario() async throws {
        for name in ["therapy", "lecture"] {
            let w = try FakeCLIWorld()
            defer { w.cleanUp() }
            try w.installFixture(name)
            let p = ReportFixtures.pipeline(CLISummaryBackend(router: w.router()))
            let transcript = try ReportFixtures.read(name, "transcript.txt")
            _ = try await p.run(transcript: transcript)
            let searches = w.calls(.claude).filter(\.toolsOn)
            XCTAssertEqual(searches.count, 1, name)
            for line in TranscriptParser.parse(transcript).map(\.text) where line.count > 25 {
                XCTAssertFalse(searches[0].everything.contains(line), "\(name): \(line)")
            }
            for call in w.calls(.claude) where !call.toolsOn {
                XCTAssertTrue(call.args.contains("--tools"), name)
            }
        }
    }
}
