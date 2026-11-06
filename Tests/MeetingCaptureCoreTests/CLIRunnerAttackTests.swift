import XCTest

@testable import MeetingCaptureCore

/// What a real CLI could do that a tidy canned answer doesn't: hang, flood, exit early,
/// ask for an API key, or quote the transcript back in an error.
final class CLIRunnerAttackTests: GuardedTestCase {

    private var world: FakeCLIWorld!
    private let request = CLIRequest.text(tier: .normal, system: "system prompt", input: "the transcript text")

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func thrown(_ cli: CLIKind = .claude, runner: CLIRunner? = nil) async -> Error? {
        do {
            _ = try await (runner ?? world.runner()).run(request, on: cli)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Timeouts

    func testAHungCLITimesOut() async throws {
        try world.installScript(.claude, modelCall: "exec sleep 20")
        let start = Date()
        let error = await thrown(runner: world.runner(timeout: 0.2))
        XCTAssertEqual(error as? CLIError, .timedOut(.claude))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// A CLI that ignores SIGTERM still ends at its timeout, because SIGKILL follows.
    func testATimeoutEndsACLIThatIgnoresTheSignal() async throws {
        try world.installScript(.claude, modelCall: "trap '' TERM; sleep 1; sleep 1")
        let start = Date()
        let error = await thrown(runner: world.runner(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "a call must end at its timeout")
        XCTAssertEqual(error as? CLIError, .timedOut(.claude))
    }

    /// A child left behind holding the output pipe doesn't keep a timed-out call waiting.
    func testATimeoutEndsACLIWhoseChildKeepsTheOutputOpen() async throws {
        try world.installScript(.claude, modelCall: "sleep 1.5")
        let start = Date()
        let error = await thrown(runner: world.runner(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a call must end at its timeout")
        XCTAssertEqual(error as? CLIError, .timedOut(.claude))
    }

    /// The CLI has finished and answered, and the timeout is cancelled by then. Only
    /// a background child is left, holding the output pipe, and the runner doesn't wait for it.
    func testACLIThatExitedIsNotWaitedOnForItsBackgroundChild() async throws {
        let answer = world.root.appendingPathComponent("answer.jsonl")
        try FakeCLIWorld.claudeOK("kept").write(to: answer, atomically: true, encoding: .utf8)
        try world.installScript(.claude, modelCall: "sleep 1.5 & cat '\(answer.path)'; exit 0")
        let start = Date()
        let result = try await world.runner().run(request, on: .claude)
        XCTAssertEqual(result.text, "kept")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.2, "a child that never ends would hang this forever")
    }

    // MARK: Pipes

    func testBigInputAndBigOutputAtOnceDontDeadlock() async throws {
        let big = String(repeating: "word ", count: 600_000)  // 3 MB, far past a pipe's buffer
        let answer = world.root.appendingPathComponent("answer.jsonl")
        try FakeCLIWorld.claudeOK(big).write(to: answer, atomically: true, encoding: .utf8)
        try world.installScript(.claude, modelCall: "cat '\(answer.path)'; wc -c > '\(world.root.path)/seen'")

        let result = try await world.runner().run(
            .text(tier: .normal, system: "s", input: big), on: .claude)

        XCTAssertEqual(result.text.count, big.count)
        let seen = try String(contentsOf: world.root.appendingPathComponent("seen"), encoding: .utf8)
        XCTAssertEqual(Int(seen.trimmingCharacters(in: .whitespacesAndNewlines)), big.utf8.count, "all of it arrived")
    }

    func testACLIThatExitsWithoutReadingItsInputIsAFailureNotACrash() async throws {
        try world.installScript(.claude, modelCall: "echo boom >&2; exit 1")
        let big = String(repeating: "word ", count: 600_000)
        do {
            _ = try await world.runner().run(.text(tier: .normal, system: "s", input: big), on: .claude)
            XCTFail("expected a failure")
        } catch let error as CLIError {
            XCTAssertEqual(error, .failed(.claude, "boom"))
        }
    }

    func testOutputThatIsntTextOrJSONIsAFailure() async throws {
        try world.installScript(.claude, modelCall: #"printf '\xff\xfe not json\n'; exit 0"#)
        guard case .failed(.claude, _) = await thrown() as? CLIError else { return XCTFail("no answer was given") }
    }

    func testJunkLinesAroundARealAnswerAreSkipped() async throws {
        let answer = "warning: something\n" + FakeCLIWorld.claudeOK("kept") + "\nmore noise\n"
        try world.install(.claude, answers: [.init(stdout: answer)])
        let result = try await world.runner().run(request, on: .claude)
        XCTAssertEqual(result.text, "kept")
    }

    // MARK: Answers that aren't

    /// Exit 0 with nothing in it isn't a summary, and mustn't be saved as one.
    func testAnEmptyAnswerIsAFailure() async throws {
        let empty = #"{"type":"result","is_error":false,"result":""}"#
        try world.install(.claude, answers: [.init(stdout: empty)])
        let error = await thrown()
        guard case .failed(.claude, _) = error as? CLIError else {
            return XCTFail("an empty summary would be saved as if it were a real one")
        }
    }

    func testAWhitespaceOnlyAnswerIsAFailure() async throws {
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK("  \n "))])
        let error = await thrown(.codex)
        guard case .failed(.codex, _) = error as? CLIError else {
            return XCTFail("a blank summary would be saved as if it were a real one")
        }
    }

    func testAnErrorResultWithAZeroExitIsStillAFailure() async throws {
        let stream = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"it broke"}"#
        try world.install(.claude, answers: [.init(stdout: stream)])
        let error = await thrown()
        XCTAssertEqual(error as? CLIError, .failed(.claude, "it broke"))
    }

    func testCodexTurnFailureAfterAMessageIsAFailure() async throws {
        let stream = """
            {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"partial"}}
            {"type":"turn.failed","error":{"message":"stream ended"}}
            """
        try world.install(.codex, answers: [.init(stdout: stream)])
        let error = await thrown(.codex)
        XCTAssertEqual(error as? CLIError, .failed(.codex, "stream ended"))
    }

    /// Unsure: from memory, Codex reports its own retries as `error` events and then
    /// succeeds. A good answer after one retry must not be thrown away.
    func testACodexRetryNoticeBeforeASuccessfulTurnDoesntLoseTheAnswer() async throws {
        let stream = """
            {"type":"error","message":"Reconnecting... 1/5"}
            {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"fine in the end"}}
            {"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":5}}
            """
        try world.install(.codex, answers: [.init(stdout: stream)])
        let result = try await world.runner().run(request, on: .codex)
        XCTAssertEqual(result.text, "fine in the end")
    }

    // MARK: Codex streams that end badly

    private func codexFailure(_ stream: String, exit: Int32 = 0) async throws -> CLIError? {
        try world.install(.codex, answers: [.init(stdout: stream, exit: exit)])
        return await thrown(.codex) as? CLIError
    }

    /// A retry notice is forgiven only by a turn that completes afterwards.
    func testATurnThatFailsAfterAnErrorNoticeIsStillAFailure() async throws {
        let stream = """
            {"type":"error","message":"Reconnecting... 1/5"}
            {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"half an answer"}}
            {"type":"turn.failed","error":{"message":"stream ended"}}
            """
        let error = try await codexFailure(stream)
        XCTAssertEqual(error, .failed(.codex, "stream ended"))
    }

    func testAFailureAfterACompletedTurnIsStillAFailure() async throws {
        let stream = """
            {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"an answer"}}
            {"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":5}}
            {"type":"error","message":"connection lost while closing"}
            """
        let error = try await codexFailure(stream)
        XCTAssertEqual(error, .failed(.codex, "connection lost while closing"))
    }

    func testACompletedTurnWithNoAgentMessageIsAnEmptyReplyAndFails() async throws {
        let stream = """
            {"type":"thread.started","thread_id":"x"}
            {"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":0}}
            """
        guard case .failed(.codex, _) = try await codexFailure(stream) else {
            return XCTFail("a summary with nothing in it would be saved")
        }
    }

    func testAnErrorWithNoCompletedTurnFailsEvenWithAMessageAndExitZero() async throws {
        let stream = """
            {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"an answer cut short"}}
            {"type":"error","message":"the model went away"}
            """
        let error = try await codexFailure(stream)
        XCTAssertEqual(error, .failed(.codex, "the model went away"))
    }

    func testAnErrorThatQuotesALimitIsAFullLimitNotAPlainFailure() async throws {
        let stream = #"{"type":"error","message":"You've hit your usage limit"}"#
        let error = try await codexFailure(stream, exit: 1)
        guard case .usageFull = error else { return XCTFail("\(String(describing: error))") }
    }

    // MARK: Output is never cut short

    private func shell(_ script: String, timeout: TimeInterval = 20) async throws -> (ProcessOutput, TimeInterval) {
        // Same route as FakeCLI.installScript: the script is an executable file, run directly.
        let url = world.root.appendingPathComponent("attack-\(UUID().uuidString).sh")
        try "#!/usr/bin/env bash\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let start = Date()
        let output = try await ProcessExec.run(
            executable: url.path, arguments: [], cwd: world.root,
            environment: ["PATH": "/usr/bin:/bin"], timeout: timeout)
        return (output, Date().timeIntervalSince(start))
    }

    /// 3 MB written just before exit: the drain has to read what's left in the pipe.
    func testBigOutputFinishingJustBeforeExitArrivesWhole() async throws {
        let (output, _) = try await shell("head -c 3000000 /dev/zero | tr '\\0' x; exit 0")
        XCTAssertEqual(output.stdout.utf8.count, 3_000_000)
        XCTAssertEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
    }

    func testBigOutputOnBothPipesAtOnceArrivesWholeOnBoth() async throws {
        let (output, elapsed) = try await shell(
            "head -c 2000000 /dev/zero | tr '\\0' e >&2 & head -c 2000000 /dev/zero | tr '\\0' o; wait")
        XCTAssertEqual(output.stdout.utf8.count, 2_000_000)
        XCTAssertEqual(output.stderr.utf8.count, 2_000_000)
        XCTAssertLessThan(elapsed, 15, "both pipes finish rather than waiting on each other")
    }

    func testABigStderrWithATinyStdoutFinishesWithBoth() async throws {
        let (output, elapsed) = try await shell("echo ok; head -c 3000000 /dev/zero | tr '\\0' e >&2; exit 3")
        XCTAssertEqual(output.stdout, "ok\n")
        XCTAssertEqual(output.stderr.utf8.count, 3_000_000)
        XCTAssertEqual(output.status, 3)
        XCTAssertLessThan(elapsed, 15)
    }

    /// Output from a child that outlives the CLI is kept for as long as it keeps coming.
    /// The lines come 40 ms apart, well inside the quiet limit, so a loaded machine has room.
    func testOutputStillFlowingAfterTheCLIExitsIsKeptToTheEnd() async throws {
        let (output, _) = try await shell(
            "(i=1; while [ $i -le 15 ]; do echo line$i; sleep 0.04; i=$((i+1)); done) & echo first; exit 0")
        let lines = output.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "first")
        XCTAssertEqual(lines.last, "line15", "cut short after \(lines.count) lines")
        XCTAssertEqual(lines.count, 16)
    }

    /// Once the child has gone quiet the call ends, even though the child still holds the pipe.
    func testAQuietChildHoldingThePipeEndsTheCallWithWhatArrived() async throws {
        let (output, elapsed) = try await shell("(echo late; sleep 3) & echo first; exit 0")
        XCTAssertTrue(output.stdout.contains("first"), output.stdout)
        XCTAssertTrue(output.stdout.contains("late"), output.stdout)
        XCTAssertLessThan(elapsed, 2.5, "it must not wait for the child's 3 s")
        XCTAssertFalse(output.timedOut)
    }

    func testACLIWithNoOutputAtAllEndsAtOnceWithEmptyStrings() async throws {
        let (output, elapsed) = try await shell("exit 0")
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(output.stderr, "")
        XCTAssertLessThan(elapsed, 2)
    }

    func testAStructuredAnswerIsTheTextAndMissingOneFailsForClaude() async throws {
        let good = #"{"type":"result","is_error":false,"result":"","structured_output":{"a":1}}"#
        try world.install(.claude, answers: [.init(stdout: good), .init(stdout: FakeCLIWorld.claudeOK("prose"))])
        let schema = CLIRequest.text(tier: .normal, system: "s", input: "i", schema: "{}")
        let runner = world.runner()
        let first = try await runner.run(schema, on: .claude)
        XCTAssertEqual(first.text, #"{"a":1}"#)
        do {
            _ = try await runner.run(schema, on: .claude)
            XCTFail("prose where a schema was asked for must not pass")
        } catch let error as CLIError {
            XCTAssertEqual(error, .failed(.claude, "no structured output in the reply"))
        }
    }

    func testCodexGetsItsSchemaAsAFileOutsideTheWorkingFolder() async throws {
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        _ = try await world.runner().run(.text(tier: .normal, system: "s", input: "i", schema: "{}"), on: .codex)
        let call = try XCTUnwrap(world.calls(.codex).first)
        let path = call.args[try XCTUnwrap(call.args.firstIndex(of: "--output-schema")) + 1]
        XCTAssertFalse(path.hasPrefix(call.cwd))
        XCTAssertEqual(call.cwdFiles, "")
    }

    // MARK: Limits

    func testAFullLimitCarriesItsResetTime() async throws {
        let stream = FakeCLIWorld.claudeOK("x", status: "rejected").replacingOccurrences(
            of: #""is_error":false"#, with: #""is_error":true"#)
        try world.install(.claude, answers: [.init(stdout: stream, exit: 1)])
        let error = await thrown()
        XCTAssertEqual(error as? CLIError, .usageFull(.claude, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)))
    }

    func testATranscriptQuotingRateLimitsInASuccessfulAnswerDoesntCountAsFull() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK("our usage limit was reached"))])
        let result = try await world.runner().run(request, on: .claude)
        XCTAssertEqual(result.text, "our usage limit was reached")
    }

    func testEachQuotaPhraseCounts() {
        for text in [
            "rate limit", "Rate-limited", "usage limit", "session limit", "You've hit your weekly limit",
            "limit reached", "Too many requests", "quota exceeded", "out of credits", "usage cap", "insufficient_quota",
        ] {
            XCTAssertTrue(CLIOutputParser.looksLikeQuota(text), text)
        }
        for text in ["model not found", "network error", "invalid request", "permission denied"] {
            XCTAssertFalse(CLIOutputParser.looksLikeQuota(text), text)
        }
    }

    // MARK: Who gets billed

    func testNotLoggedInAndBadStatusOutputAreNotReady() async throws {
        for status in [#"{"loggedIn":false}"#, "not json", ""] {
            try world.install(.claude, answers: [.init(stdout: "")], authStatus: status)
            let availability = await world.runner().availability(.claude)
            XCTAssertEqual(availability, .missing(.notLoggedIn(.claude)), status)
        }
        try world.install(.codex, answers: [.init(stdout: "")], authStatus: "Not logged in")
        let codex = await world.runner().availability(.codex)
        XCTAssertEqual(codex, .missing(.notLoggedIn(.codex)))
    }

    func testAnUnknownClaudeLoginIsTreatedAsBilling() async throws {
        try world.install(.claude, answers: [.init(stdout: "")], authStatus: #"{"loggedIn":true}"#)
        let availability = await world.runner().availability(.claude)
        XCTAssertEqual(availability, .missing(.apiBillingRefused(.claude, "unknown")))
    }

    func testOptingInAllowsAPIBillingAndStillFiltersTheEnvironment() async throws {
        try world.install(
            .claude, answers: [.init(stdout: FakeCLIWorld.claudeOK(apiKeySource: "ANTHROPIC_API_KEY"))],
            authStatus: #"{"loggedIn":true,"authMethod":"api_key"}"#)
        let runner = world.runner(allowAPIBilling: true)
        let availability = await runner.availability(.claude)
        XCTAssertEqual(availability, .ready)
        let result = try await runner.run(request, on: .claude)
        XCTAssertEqual(result.text, "fake answer")
        XCTAssertFalse(try XCTUnwrap(world.calls(.claude).first).env.contains("ANTHROPIC_API_KEY"))
    }

    func testAMissingCLIIsNotInstalledRatherThanAFailure() async throws {
        let availability = await world.runner().availability(.claude)
        XCTAssertEqual(availability, .missing(.notInstalled(.claude)))
        let error = await thrown()
        XCTAssertEqual(error as? CLIError, .notInstalled(.claude))
    }

    /// The check that says it's refused, on the path that actually starts a process.
    func testAnUnsafeModelNameStartsNoProcess() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
        let models = [CLIKind.claude: CLITierModels(cheap: "x", normal: "--dangerous", frontier: "x")]
        guard case .badRequest = await thrown(runner: world.runner(models: models)) as? CLIError else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(world.calls(.claude).count, 0)
    }

    func testAModelNameCantCarryAnotherLine() {
        for bad in ["haiku\n", "haiku\n--dangerous", "\nhaiku", "", " haiku", "-x"] {
            XCTAssertFalse(CLIArguments.isSafeModelName(bad), bad)
        }
        XCTAssertTrue(CLIArguments.isSafeModelName("claude-sonnet-4-6[1m]"))
    }

    // MARK: Keeping the transcript in its place

    func testCodexGetsTheTranscriptOnStdinOnly() async throws {
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        _ = try await world.runner().run(request, on: .codex)
        let call = try XCTUnwrap(world.calls(.codex).first)
        XCTAssertEqual(call.stdin, "the transcript text")
        XCTAssertFalse(call.args.joined(separator: " ").contains("the transcript text"))
    }

    func testTheTempFolderIsGoneAfterACallAndAfterAFailure() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK()), .init(stdout: "", exit: 1)])
        let runner = world.runner()
        _ = try await runner.run(request, on: .claude)
        _ = try? await runner.run(request, on: .claude)
        let calls = world.calls(.claude)
        XCTAssertEqual(calls.count, 2)
        for call in calls { XCTAssertFalse(FileManager.default.fileExists(atPath: call.cwd), call.cwd) }
    }

    func testAnErrorTextIsScrubbedAndCutWhereverItCameFrom() async throws {
        let email = "someone" + "@example.com"
        let long = String(repeating: "x", count: 1000)
        let stream = #"{"type":"result","is_error":true,"result":"quoted \#(email) \#(long)"}"#
        try world.install(.claude, answers: [.init(stdout: stream, exit: 1)])
        guard case .failed(_, let message) = await thrown() as? CLIError else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.contains(email))
        XCTAssertLessThanOrEqual(message.count, 400)
    }

    // MARK: Tool lockdown

    func testAClaudeSearchCanOnlyUseWebSearch() throws {
        let args = CLIArguments.claude(try .conceptSearch(tier: .cheap, concepts: ["attachment theory"]), model: "m")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--tools")) + 1], "WebSearch")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--allowedTools")) + 1], "WebSearch")
        XCTAssertTrue(args.contains("--safe-mode"))
    }

    func testIfTheFeatureListCantBeReadTheShellIsStillOff() async throws {
        try world.install(.claude, answers: [.init(stdout: "")])
        let log = world.root.appendingPathComponent("args")
        try world.installScript(
            .codex,
            modelCall:
                #"printf '%s\n' "$@" > '\#(log.path)'; cat > /dev/null; echo '\#(FakeCLIWorld.codexOK().replacingOccurrences(of: "\n", with: "'; echo '"))'"#,
            featuresList: "exit 1")
        _ = try await world.runner().run(request, on: .codex)
        let args = try String(contentsOf: log, encoding: .utf8)
        for feature in ["shell_tool", "unified_exec", "apps", "plugins", "code_mode_host", "computer_use"] {
            XCTAssertTrue(args.contains("features.\(feature)=false"), feature)
        }
    }

    func testBenignFeaturesAreNeverAlsoOnTheAlwaysOffList() {
        XCTAssertTrue(CLIArguments.codexBenignFeatures.isDisjoint(with: CLIArguments.codexFeaturesAlwaysOff))
    }

    func testAToolNamedInTheBenignListStillGoesOffIfAlwaysOffListsIt() {
        let off = CLIArguments.codexFeaturesOff(listed: ["fast_mode", "shell_tool", "shell_tool", "new_thing"])
        XCTAssertEqual(off.filter { $0 == "shell_tool" }.count, 1)
        XCTAssertTrue(off.contains("new_thing"))
        XCTAssertFalse(off.contains("fast_mode"))
    }

    func testAPathWithAQuoteStaysOneTOMLString() {
        let args = CLIArguments.codex(
            .text(tier: .normal, system: "s", input: "i"), model: "m", cwd: "/c", schemaPath: nil,
            instructionsPath: #"/tmp/a"b\c.md"#, featuresOff: [])
        XCTAssertTrue(args.contains(#"model_instructions_file="/tmp/a\"b\\c.md""#), "\(args)")
    }

    func testConceptSearchLimits() throws {
        let eight = Array(repeating: "attachment", count: 8)
        XCTAssertNoThrow(try CLIRequest.conceptSearch(tier: .cheap, concepts: eight))
        XCTAssertThrowsError(try CLIRequest.conceptSearch(tier: .cheap, concepts: eight + ["one more"]))
        XCTAssertNoThrow(try CLIRequest.conceptSearch(tier: .cheap, concepts: ["one two three four five six"]))
        XCTAssertThrowsError(
            try CLIRequest.conceptSearch(tier: .cheap, concepts: ["one two three four five six seven"]))
        XCTAssertThrowsError(try CLIRequest.conceptSearch(tier: .cheap, concepts: [String(repeating: "x", count: 61)]))
        XCTAssertThrowsError(try CLIRequest.conceptSearch(tier: .cheap, concepts: ["   "]))
        XCTAssertThrowsError(
            try CLIRequest.conceptSearch(tier: .cheap, concepts: ["第３次"]), "a full-width digit is a digit")
    }
}
