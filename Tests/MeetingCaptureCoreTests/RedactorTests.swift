import XCTest

@testable import MeetingCaptureCore

final class RedactorTests: XCTestCase {

    private static var fixtureDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/redaction").path
    }

    private func fixtures() throws -> [RedactionFixture] {
        try RedactionFixture.load(directory: Self.fixtureDirectory)
    }

    /// The regression score from the spec: at least 95% of formatted values across
    /// old and new cases, no false positives. Prints every miss, by fixture id.
    func testScoreOnFixtures() throws {
        var caught = 0
        var total = 0
        var falsePositives = 0
        var misses: [String] = []
        for fixture in try fixtures() {
            let result = Redactor.redact(fixture.text)
            for value in fixture.formatted + (fixture.spoken ?? []) {
                total += 1
                // Strict: one token must cover the whole value. Catching only the
                // end of "grace underscore o at example dot com" still leaks the start.
                if !result.tokens.values.contains(where: { $0.contains(value) }) {
                    misses.append("\(fixture.id): missed: \(value)")
                } else {
                    caught += 1
                }
            }
            for decoy in fixture.decoys ?? [] where !result.text.contains(decoy) {
                falsePositives += 1
                misses.append("\(fixture.id): decoy caught: \(decoy)")
            }
            let labelled = fixture.formatted + (fixture.spoken ?? [])
            for (token, value) in result.tokens
            where !labelled.contains(where: { $0.contains(value) || value.contains($0) }) {
                falsePositives += 1
                misses.append("\(fixture.id): false positive as \(token)")
            }
        }
        let score = Double(caught) / Double(max(total, 1))
        print(
            "REDACTION SCORE: \(caught)/\(total) = \(String(format: "%.1f", score * 100))%, false positives \(falsePositives)"
        )
        for miss in misses { print("  \(miss)") }
        XCTAssertGreaterThanOrEqual(score, 0.95, misses.joined(separator: "\n"))
        XCTAssertEqual(falsePositives, 0, misses.joined(separator: "\n"))
    }

    func testEveryFixtureRoundTrips() throws {
        for fixture in try fixtures() {
            let result = Redactor.redact(fixture.text)
            let restored = Redactor.restore(result.text, tokens: result.tokens)
            XCTAssertEqual(restored.text, fixture.text, fixture.id)
            XCTAssertEqual(restored.flagged, [], fixture.id)
        }
    }

    func testRestoreOnChineseText() {
        let email = "chen.xy" + "@example.cn"
        let text = "陈小雨负责这个，邮箱\(email)，手机13800138000。"
        let result = Redactor.redact(text)
        XCTAssertFalse(result.text.contains(email))
        XCTAssertFalse(result.text.contains("13800138000"))
        XCTAssertTrue(result.text.contains("陈小雨"), "names aren't redacted: a documented limit")

        let answer = "负责人：陈小雨。联系方式：" + result.tokens.keys.sorted().joined(separator: "、") + "。"
        let restored = Redactor.restore(answer, tokens: result.tokens)
        XCTAssertTrue(restored.text.contains(email))
        XCTAssertTrue(restored.text.contains("13800138000"))
        XCTAssertEqual(restored.flagged, [])
    }

    func testValuesRightAfterChineseAreCaught() {
        XCTAssertFalse(Redactor.redact("账号DE89 3704 0044 0532 0130 00。").text.contains("DE89"))
        XCTAssertFalse(Redactor.redact("社保078-05-1120，").text.contains("078-05-1120"))
        XCTAssertFalse(Redactor.redact("电话415-555-0177吧").text.contains("415-555-0177"))
    }

    func testSameValueGetsOneToken() {
        let email = "a" + "@example.com"
        let result = Redactor.redact("\(email) and again \(email)")
        XCTAssertEqual(result.tokens.count, 1)
        XCTAssertEqual(result.text, "<EMAIL_1> and again <EMAIL_1>")
    }

    func testUnknownAndMangledTokensStayVisibleAndFlagged() {
        let tokens = ["<EMAIL_1>": "a" + "@example.com"]
        for broken in ["<EMAIL_9>", "<EMAIL 1>", "<email_1>", "EMAIL_1", "<PHONE_3>"] {
            let restored = Redactor.restore("Reach them at \(broken).", tokens: tokens)
            XCTAssertTrue(restored.text.contains(broken), broken)
            XCTAssertEqual(restored.flagged, [broken], broken)
            XCTAssertFalse(restored.text.contains("example.com"), "never guessed: \(broken)")
        }
    }

    func testOrdinaryWordsAreNotFlaggedAsMangled() {
        let restored = Redactor.restore("Email 2 went out, and card 3 of the deck. Phone 5 rang.", tokens: [:])
        XCTAssertEqual(restored.flagged, [])
    }

    func testRestoreIsOnePass() {
        // A value that looks like a token must not be expanded again.
        let tokens = ["<EMAIL_1>": "<PHONE_1>", "<PHONE_1>": "secret"]
        XCTAssertEqual(Redactor.restore("<EMAIL_1>", tokens: tokens).text, "<PHONE_1>")
    }

    func testLiteralTokenInTranscriptCannotCollide() {
        let email = "a" + "@example.com"
        let result = Redactor.redact("They typed <EMAIL_1> and \(email).")
        XCTAssertEqual(result.tokens.values.first, email)
        XCTAssertEqual(result.tokens.keys.first, "<EMAIL_2>")
    }

    func testChecksumsDecide() {
        XCTAssertTrue(Redactor.ibanValid("DE89 3704 0044 0532 0130 00"))
        XCTAssertFalse(Redactor.ibanValid("DE89 3704 0044 0532 0130 01"))
        XCTAssertTrue(Redactor.luhnValid("4242 4242 4242 4242"))
        XCTAssertFalse(Redactor.luhnValid("4242 4242 4242 4241"))
        XCTAssertFalse(Redactor.luhnValid("0000 0000 0000 0000"))
        XCTAssertTrue(Redactor.cnIDValid("11010519491231002X"))
        XCTAssertFalse(Redactor.cnIDValid("110105194912310021"))
        XCTAssertFalse(Redactor.ssnValid("000-12-3456"))
    }

    func testIBANFollowedByACapitalizedWord() {
        let result = Redactor.redact("Pay DE89 3704 0044 0532 0130 00 NEXT week")
        XCTAssertTrue(result.text.contains("NEXT week"))
        XCTAssertFalse(result.text.contains("DE89"))
    }

    func testURLTokenKeepsTheURL() {
        let result = Redactor.redact("See https://dash.example.com/share?to" + "ken=abc123def456ghi789 now")
        XCTAssertEqual(result.text, "See https://dash.example.com/share?token=<URL_TOKEN_1> now")
    }

    // Finding from the independent cases (ind-05, ind-08): PHONE took three groups out of a longer number.
    func testPhoneDoesNotMatchInsideALongerGroupedNumber() {
        for clean in ["Sheet says 4601 5790 3197 3408 for it.", "My sheet says DE16 5541 9484 2317 5422 14."] {
            XCTAssertEqual(Redactor.redact(clean).text, clean, clean)
        }
    }

    // Finding from the independent cases (ind-07): UK mobile layout.
    func testTrunkPrefixPhoneFormat() {
        XCTAssertEqual(Redactor.redact("my mobile 07700 900461, before nine").text, "my mobile <PHONE_1>, before nine")
    }

    // Finding from the independent cases (ind-10): the start of the address leaked.
    func testSpokenEmailKeepsItsWholeLocalPart() {
        XCTAssertEqual(Redactor.redact("It's grace underscore o at example dot com.").text, "It's <EMAIL_SPOKEN_1>.")
    }

    // Known limit, kept visible so a change in behaviour gets noticed.
    func testBareNineDigitSSNIsADocumentedMiss() {
        XCTAssertEqual(Redactor.redact("the form asks for 100994823, no dashes").tokens.count, 0)
    }

    func testOrdinaryNumbersPass() {
        for clean in [
            "[00:00:04] We ship on 2026-11-06 at 10:30.",
            "Budget is 42,000 dollars, or 1,250,000 yen.",
            "Version 12.4.1 of build 20261106.",
            "Room 415, ticket ABC-1234, order 100-200-300.",
            "We looked at this and that.",
        ] {
            XCTAssertEqual(Redactor.redact(clean).text, clean, clean)
        }
    }
}

/// The transcript-to-report path on fake CLIs. Ported from the single-summary pipeline:
/// each test keeps the behaviour it guarded (spec 04 replaced the style with a scenario).
final class SummaryPipelineTests: GuardedTestCase {

    private func model(_ call: FakeCLIWorld.Call) -> String {
        call.args[call.args.firstIndex(of: "--model")! + 1]
    }

    func testRedactedValueNeverReachesAnyCallAndComesBackInTheAnswer() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        let email = "priya" + "@example.com"
        // The fake model copies the token, as the prompt asks.
        let sections = Replies.sections(["summary": ["Send it to <EMAIL_1>."]])
        try world.install(
            .claude,
            answers: [
                FakeCLIWorld.jsonScript(Replies.classify("meeting")),
                FakeCLIWorld.jsonScript(sections),
                FakeCLIWorld.jsonScript(Replies.review(["summary": ["Send it to <EMAIL_1>."]])),
            ])
        let outcome = try await SummaryPipeline(backend: CLISummaryBackend(router: world.router()), redaction: true)
            .run(transcript: "[00:00:01] You: Send the contract to \(email), please.")

        let calls = world.calls(.claude)
        for call in calls { XCTAssertFalse(call.everything.contains(email)) }
        XCTAssertEqual(calls.count, 3, "classify, sections, review (the meeting template has no concepts)")
        XCTAssertEqual(model(calls[0]), "haiku", "the classifier is cheap tier")
        XCTAssertEqual(model(calls[1]), "sonnet", "the sections are normal tier")
        XCTAssertEqual(model(calls[2]), "opus", "the review is frontier tier")
        XCTAssertTrue(calls[1].args.joined().contains("Copy a token exactly"))
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "Send it to \(email).")
        XCTAssertEqual(outcome.redactedValues, 1)
        XCTAssertTrue(outcome.flaggedTokens.isEmpty)
    }

    func testRedactionOffSendsTheText() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        let email = "priya" + "@example.com"
        try world.install(
            .claude,
            answers: [
                FakeCLIWorld.jsonScript(Replies.sections(["summary": ["ok"]])),
                FakeCLIWorld.jsonScript(Replies.review(["summary": ["ok"]])),
            ])
        _ = try await SummaryPipeline(backend: CLISummaryBackend(router: world.router()), redaction: false)
            .run(transcript: "Mail \(email)", forcedScenario: "meeting")
        XCTAssertTrue(try XCTUnwrap(world.calls(.claude).first).stdin.contains(email))
    }

    func testForcedScenarioSkipsTheClassifier() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        try world.install(
            .claude,
            answers: [
                FakeCLIWorld.jsonScript(Replies.sections(["summary": ["notes"]])),
                FakeCLIWorld.jsonScript(Replies.review(["summary": ["notes"]])),
            ])
        let outcome = try await SummaryPipeline(backend: CLISummaryBackend(router: world.router()), redaction: true)
            .run(transcript: "hello", forcedScenario: "general")
        XCTAssertEqual(outcome.report.scenario, "general")
        XCTAssertEqual(world.calls(.claude).count, 2, "sections and review only")
        XCTAssertEqual(model(world.calls(.claude)[0]), "sonnet", "the first call is the sections, not a classifier")
    }

    func testReportSaysWhatHappened() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        try world.install(.claude, answers: [.init(stdout: "", exit: 1, stderr: "usage limit reached")])
        try world.install(
            .codex,
            answers: [
                FakeCLIWorld.jsonScript(Replies.sections(["summary": ["Mail <EMAIL_7>."]]), cli: .codex),
                FakeCLIWorld.jsonScript(Replies.review(["summary": ["Mail <EMAIL_7>."]]), cli: .codex),
            ])
        let outcome = try await SummaryPipeline(backend: CLISummaryBackend(router: world.router()), redaction: true)
            .run(transcript: "hello", forcedScenario: "meeting")
        XCTAssertEqual(outcome.flaggedTokens, ["<EMAIL_7>"])
        XCTAssertTrue(
            outcome.report.notices.joined().contains("<EMAIL_7>"), "an unknown token is flagged in the notices")
        XCTAssertTrue(outcome.report.notices.joined().contains("Codex"), "a switch of CLI goes in the report")
    }
}
