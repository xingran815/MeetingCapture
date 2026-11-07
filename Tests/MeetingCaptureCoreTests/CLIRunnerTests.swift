import XCTest

@testable import MeetingCaptureCore

final class CLIRunnerTests: GuardedTestCase {

    private var world: FakeCLIWorld!

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private let request = CLIRequest.text(tier: .normal, system: "system prompt", input: "the transcript text")

    func testClaudeGetsToolsOffInputOnStdinEmptyCwdAndAllowListedEnvironment() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
        let result = try await world.runner().run(request, on: .claude)
        XCTAssertEqual(result.text, "fake answer")
        XCTAssertEqual(result.apiKeySource, "none")

        let call = try XCTUnwrap(world.calls(.claude).first)
        XCTAssertFalse(call.args.contains("the transcript text"), "input belongs on stdin, not in arguments")
        XCTAssertEqual(call.stdin, "the transcript text")
        let tools = try XCTUnwrap(call.args.firstIndex(of: "--tools"))
        XCTAssertEqual(call.args[tools + 1], "")
        for flag in ["--safe-mode", "--strict-mcp-config", "--no-session-persistence", "-p"] {
            XCTAssertTrue(call.args.contains(flag), flag)
        }
        XCTAssertEqual(call.args[call.args.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(call.cwdFiles, "", "cwd must be empty")
        XCTAssertFalse(call.env.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(call.env.contains("OPENAI_API_KEY"))
        XCTAssertFalse(call.env.contains("SOME_OTHER"))
    }

    func testCodexFlagsSwitchOffEveryListedFeatureExceptBenignOnes() async throws {
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        let result = try await world.runner().run(request, on: .codex)
        XCTAssertEqual(result.text, "fake answer")

        let call = try XCTUnwrap(world.calls(.codex).first)
        XCTAssertEqual(call.stdin, "the transcript text")
        XCTAssertEqual(call.cwdFiles, "", "the schema and prompt files must not sit in cwd")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] {
            XCTAssertTrue(call.args.contains(flag), flag)
        }
        XCTAssertEqual(call.args[call.args.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertEqual(call.args[call.args.firstIndex(of: "-m")! + 1], "gpt-6.1-sol")
        XCTAssertTrue(call.args.contains("features.brand_new_tool=false"), "an unknown new feature stays off")
        XCTAssertTrue(call.args.contains("features.shell_tool=false"))
        XCTAssertFalse(call.args.contains("features.fast_mode=false"), "benign features stay on")
        XCTAssertTrue(call.args.contains("web_search=\"disabled\""))
        XCTAssertEqual(call.args.last, "-")
        XCTAssertFalse(call.env.contains("OPENAI_API_KEY"))
    }

    func testTierMapping() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        let runner = world.runner()
        for tier in ModelTier.allCases {
            _ = try await runner.run(.text(tier: tier, system: "s", input: "i"), on: .claude)
            _ = try await runner.run(.text(tier: tier, system: "s", input: "i"), on: .codex)
        }
        XCTAssertEqual(
            world.calls(.claude).map { $0.args[$0.args.firstIndex(of: "--model")! + 1] }, ["haiku", "sonnet", "opus"])
        XCTAssertEqual(
            world.calls(.codex).map { $0.args[$0.args.firstIndex(of: "-m")! + 1] },
            ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"])
    }

    func testAPIKeyLoginIsRefusedBeforeAnyCall() async throws {
        try world.install(
            .claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())],
            authStatus: #"{"loggedIn":true,"authMethod":"api_key"}"#)
        try world.install(
            .codex, answers: [.init(stdout: FakeCLIWorld.codexOK())],
            authStatus: "Logged in using an API key")
        let runner = world.runner()
        let claude = await runner.availability(.claude)
        let codex = await runner.availability(.codex)
        XCTAssertEqual(claude, .missing(.apiBillingRefused(.claude, "api_key")))
        XCTAssertEqual(codex, .missing(.apiBillingRefused(.codex, "API key login")))
    }

    func testAPIKeySourceInTheStreamIsRefused() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK(apiKeySource: "ANTHROPIC_API_KEY"))])
        do {
            _ = try await world.runner().run(request, on: .claude)
            XCTFail("a call billing an API key must be refused")
        } catch let error as CLIError {
            XCTAssertEqual(error, .apiBillingRefused(.claude, "ANTHROPIC_API_KEY"))
        }
    }

    func testUnsafeModelNameFromConfigIsRefused() {
        XCTAssertFalse(CLIArguments.isSafeModelName("--dangerous"))
        XCTAssertFalse(CLIArguments.isSafeModelName("a b"))
        XCTAssertTrue(CLIArguments.isSafeModelName("gpt-6.1-sol"))
        XCTAssertTrue(CLIArguments.isSafeModelName("haiku"))
    }

    func testAnswerDiscussingRateLimitsIsNotAFullLimit() {
        let parsed = CLIOutputParser.parseClaude(FakeCLIWorld.claudeOK("We hit a rate limit and our quota is low."))
        XCTAssertEqual(CLIOutputParser.outcome(of: parsed, exitCode: 0, stderr: ""), .ok)
    }

    func testFullLimitSignals() {
        var parsed = ParsedCLIOutput()
        XCTAssertEqual(
            CLIOutputParser.outcome(of: parsed, exitCode: 1, stderr: "You've hit your session limit"),
            .usageFull(resetsAt: nil))
        parsed.httpStatus = 429
        parsed.isError = true
        XCTAssertEqual(CLIOutputParser.outcome(of: parsed, exitCode: 1, stderr: ""), .usageFull(resetsAt: nil))
        parsed = ParsedCLIOutput()
        parsed.isError = true
        parsed.errorText = "model not found"
        XCTAssertEqual(CLIOutputParser.outcome(of: parsed, exitCode: 1, stderr: ""), .failed("model not found"))
    }

    func testCLIErrorTextIsScrubbedBeforeItCanBeShown() async throws {
        let email = "someone" + "@example.com"
        try world.install(.claude, answers: [.init(stdout: "", exit: 1, stderr: "bad input near \(email)")])
        do {
            _ = try await world.runner().run(request, on: .claude)
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(email))
        }
    }

    func testWebSearchIsCountedFromToolUseEvents() {
        let stream = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch"}]}}
            {"type":"result","is_error":false,"result":"ok","modelUsage":{"x":{"webSearchRequests":0}}}
            """
        XCTAssertEqual(CLIOutputParser.parseClaude(stream).webSearchCount, 1)
    }

    // Finding from the live check: with every feature off, Codex's search failed and
    // the model answered from memory.
    func testCodexSearchKeepsOnlyItsHostOn() throws {
        let off = CLIArguments.codexFeaturesOff(listed: ["shell_tool", "code_mode_host"])
        let search = CLIArguments.codex(
            try .conceptSearch(tier: .cheap, concepts: ["window of tolerance"]), model: "m", cwd: "/c",
            schemaPath: nil, instructionsPath: "/i", featuresOff: off)
        XCTAssertFalse(search.contains("features.code_mode_host=false"))
        XCTAssertTrue(search.contains("features.shell_tool=false"), "the shell stays off during a search")
        XCTAssertTrue(search.contains("web_search=\"live\""))

        let plain = CLIArguments.codex(
            .text(tier: .normal, system: "s", input: "i"), model: "m", cwd: "/c",
            schemaPath: nil, instructionsPath: "/i", featuresOff: off)
        XCTAssertTrue(plain.contains("features.code_mode_host=false"), "a call with transcript text keeps it off")
        XCTAssertTrue(plain.contains("web_search=\"disabled\""))
    }

    func testCodexFeatureListParsing() {
        let listed = CLIArguments.parseCodexFeatureList(
            "shell_tool stable true\nunder_dev under development false\nnot a row\n")
        XCTAssertEqual(listed, ["shell_tool", "under_dev"])
    }
}

/// Spec: "A test proves transcript text never appears in a call with tools on."
final class ToolsOffTests: GuardedTestCase {

    func testTranscriptNeverReachesACallWithToolsOn() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        for cli in CLIKind.allCases {
            try world.install(
                cli,
                answers: [
                    FakeCLIWorld.jsonScript(Replies.classify("meeting"), cli: cli),
                    FakeCLIWorld.jsonScript(Replies.sections(["summary": ["notes"]]), cli: cli),
                    FakeCLIWorld.jsonScript(Replies.review(["summary": ["notes"]]), cli: cli),
                ])
        }
        let transcript = "[00:00:01] You: The merger with Northwind closes on the ninth, keep it quiet."

        for cli in CLIKind.allCases {
            let router = world.router(primary: cli)
            let outcome = try await SummaryPipeline(backend: CLISummaryBackend(router: router), redaction: true)
                .run(transcript: transcript)
            XCTAssertFalse(items(outcome.report, "summary").isEmpty)
            _ = try await router.call(try .conceptSearch(tier: .cheap, concepts: ["cognitive defusion"]))
        }

        var sawToolsOn = 0
        var sawTranscript = 0
        for cli in CLIKind.allCases {
            for call in world.calls(cli) {
                if call.toolsOn {
                    sawToolsOn += 1
                    XCTAssertFalse(call.everything.contains("Northwind"), "transcript text in a call with tools on")
                    XCTAssertFalse(call.everything.contains("merger"))
                    XCTAssertTrue(call.stdin.contains("cognitive defusion"))
                } else if call.stdin.contains("Northwind") {
                    sawTranscript += 1
                }
            }
        }
        XCTAssertEqual(sawToolsOn, 2, "both CLIs ran a search")
        XCTAssertEqual(
            sawTranscript, 6, "the transcript did go out, on classify, sections and review calls with tools off")
    }

    func testConceptSearchRefusesAnythingLikeATranscriptLine() {
        for bad in [
            "[00:00:01] You: I keep not calling my sister back",
            "Anna called on the 9th",
            "someone" + "@example.com",
            "<EMAIL_1>",
            "a very long phrase that goes on and on and is clearly not a concept name at all",
            "two\nlines",
        ] {
            XCTAssertThrowsError(try CLIRequest.conceptSearch(tier: .cheap, concepts: [bad]), bad)
        }
        XCTAssertNoThrow(try CLIRequest.conceptSearch(tier: .cheap, concepts: ["window of tolerance"]))
        XCTAssertThrowsError(try CLIRequest.conceptSearch(tier: .cheap, concepts: []))
    }

    func testPlainRequestsCannotCarryTools() {
        let request = CLIRequest.text(tier: .frontier, system: "s", input: "i")
        XCTAssertFalse(request.webSearch)
        let args = CLIArguments.claude(request, model: "opus")
        XCTAssertFalse(args.contains("WebSearch"))
    }
}
