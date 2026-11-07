import XCTest

@testable import MeetingCaptureCore

/// Answers URLSession requests in a test. Nothing leaves the machine.
final class StubLLMServer: URLProtocol {
    struct Seen {
        let request: URLRequest
        let body: String
    }

    static var seen: [Seen] = []
    static var replies: [(status: Int, body: String)] = []

    static func reset(replies: [(status: Int, body: String)]) {
        seen = []
        self.replies = replies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                if count <= 0 { break }
                body.append(contentsOf: chunk[0..<count])
            }
        }
        Self.seen.append(Seen(request: request, body: String(decoding: body, as: UTF8.self)))
        let reply = Self.replies.count > 1 ? Self.replies.removeFirst() : (Self.replies.first ?? (500, ""))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The API route had no tests. These run it against a stub, with invented keys.
final class SummaryRouteTests: GuardedTestCase {

    private var dir: URL!
    private let fakeKey = "fake-key-for-tests"
    private let email = "priya" + "@example.com"

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(StubLLMServer.self)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        APIKeyStore.pathOverride = dir.appendingPathComponent("keys.json")
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubLLMServer.self)
        APIKeyStore.pathOverride = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func summarizer(
        base: String = "https://llm.example.com/v1", style: LLMAPIStyle = .openAIChat,
        reasoning: ReasoningStyle = .none, effort: ReasoningEffort = .off
    ) -> Summarizer {
        let key = fakeKey
        return Summarizer(
            baseURL: URL(string: base)!, apiKeyProvider: { key }, model: "fake-model", apiStyle: style,
            reasoningStyle: reasoning, reasoningEffort: effort)
    }

    private func json(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private let openAIReply = #"{"choices":[{"message":{"content":"Send it to <EMAIL_1>."}}]}"#

    // MARK: The spec's rule: nothing formatted in any request

    private func apiReply(_ content: String) -> (Int, String) {
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (200, String(decoding: body, as: UTF8.self))
    }

    func testRedactedValuesStayOutOfEveryAPIRequestAndComeBackInTheAnswer() async throws {
        StubLLMServer.reset(replies: [
            apiReply(Replies.classify("meeting")),
            apiReply(Replies.sections(["summary": ["Send it to <EMAIL_1>."]])),
            apiReply(Replies.review(["summary": ["Send it to <EMAIL_1>."]])),
        ])
        let pipeline = SummaryPipeline(
            backend: APISummaryBackend(summarizer: summarizer(), label: "x"), redaction: true)
        let outcome = try await pipeline.run(transcript: "[00:00:01] You: Send the contract to \(email), please.")

        XCTAssertEqual(
            StubLLMServer.seen.count, 3, "classify, sections and review (no concept search on the API route)")
        for seen in StubLLMServer.seen {
            XCTAssertFalse(seen.body.contains(email), seen.body)
            XCTAssertFalse(seen.request.url?.absoluteString.contains(fakeKey) ?? true, "a key doesn't belong in a URL")
        }
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "Send it to \(email).")
    }

    /// The API profile has one model and no tools, so a scenario with a concepts section
    /// still makes a report and says why it has no sources.
    func testTheAPIRouteHasNoConceptSearchAndSaysSo() async throws {
        StubLLMServer.reset(replies: [
            apiReply(Replies.sections(["summary": ["s"], "concepts": ["cognitive defusion"]])),
            apiReply(Replies.review(["summary": ["s"], "concepts": ["cognitive defusion"]])),
        ])
        let outcome = try await SummaryPipeline(
            backend: APISummaryBackend(summarizer: summarizer(), label: "x"), redaction: true
        ).run(transcript: "[00:00:01] You: hello", forcedScenario: "therapy")
        XCTAssertEqual(StubLLMServer.seen.count, 2)
        XCTAssertTrue(outcome.report.notices.joined().contains("need a subscription CLI"), "\(outcome.report.notices)")
        XCTAssertNil(items(outcome.report, "concepts").first?.sources)
    }

    // MARK: Wire shapes

    func testOpenAIRequestUsesBearerAuthAndAChatBody() async throws {
        StubLLMServer.reset(replies: [(200, openAIReply)])
        _ = try await summarizer().complete(system: "the system prompt", user: "words")
        let seen = try XCTUnwrap(StubLLMServer.seen.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeKey)")
        XCTAssertNil(seen.request.value(forHTTPHeaderField: "x-api-key"))
        let body = try json(seen.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "the system prompt")
        XCTAssertEqual(messages[1]["content"] as? String, "words")
    }

    func testAnthropicRequestUsesItsOwnHeaderAndHasNoTemperature() async throws {
        StubLLMServer.reset(replies: [(200, #"{"content":[{"type":"text","text":"ok"}]}"#)])
        let answer = try await summarizer(base: "https://api.anthropic.example/v1", style: .anthropicMessages)
            .complete(system: "the system prompt", user: "words")
        XCTAssertEqual(answer, "ok")
        let seen = try XCTUnwrap(StubLLMServer.seen.first)
        XCTAssertEqual(seen.request.url?.lastPathComponent, "messages")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-api-key"), fakeKey)
        XCTAssertNil(seen.request.value(forHTTPHeaderField: "Authorization"), "the key goes in one place")
        let body = try json(seen.body)
        XCTAssertNil(body["temperature"])
        XCTAssertNotNil(body["max_tokens"])
        XCTAssertEqual(
            body["system"] as? String, "the system prompt", "Anthropic takes the system prompt at the top level")
    }

    func testReasoningIsSentInTheShapeEachProviderReads() async throws {
        StubLLMServer.reset(replies: [(200, openAIReply)])
        _ = try await summarizer(reasoning: .thinking, effort: .medium).complete(system: "s", user: "x")
        _ = try await summarizer(reasoning: .thinking, effort: .off).complete(system: "s", user: "x")
        _ = try await summarizer(reasoning: .openai, effort: .high).complete(system: "s", user: "x")
        _ = try await summarizer(reasoning: .openai, effort: .off).complete(system: "s", user: "x")
        let bodies = try StubLLMServer.seen.map { try json($0.body) }
        let thinkingOn = try XCTUnwrap(bodies[0]["thinking"] as? [String: Any])
        XCTAssertEqual(thinkingOn["type"] as? String, "enabled")
        XCTAssertEqual(thinkingOn["budget_tokens"] as? Int, 16_000)
        XCTAssertEqual((bodies[1]["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(bodies[2]["reasoning_effort"] as? String, "high")
        XCTAssertNil(bodies[3]["reasoning_effort"])
    }

    // MARK: Failures

    func testNoKeyStopsBeforeAnyRequest() async throws {
        StubLLMServer.reset(replies: [(200, openAIReply)])
        let keyless = Summarizer(
            baseURL: URL(string: "https://llm.example.com")!, apiKeyProvider: { nil }, model: "m")
        do {
            _ = try await keyless.complete(system: "s", user: "x")
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(StubLLMServer.seen.count, 0)
    }

    func testAnHTTPErrorSurfacesWithTheStatusAndNeverTheKey() async throws {
        StubLLMServer.reset(replies: [(429, "slow down")])
        do {
            _ = try await summarizer().complete(system: "s", user: "x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("429"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(fakeKey))
        }
    }

    /// The CLI route scrubs its errors because they can quote their input. This route's
    /// error reaches the screen too, so it has to be scrubbed the same way.
    func testAProviderErrorQuotingItsInputIsScrubbedLikeACLIError() async throws {
        StubLLMServer.reset(replies: [(400, #"{"error":"bad input near \#(email)"}"#)])
        var message = ""
        do {
            _ = try await summarizer().complete(system: "s", user: "x")
            XCTFail("expected a failure")
        } catch {
            message = error.localizedDescription
        }
        XCTAssertFalse(message.contains(email), message)
    }

    /// Summarize.swift's own comment says a reasoning model can leave `content` empty.
    func testAnEmptyAPIAnswerIsAFailureNotAnEmptySummary() async throws {
        StubLLMServer.reset(replies: [(200, #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#)])
        let answer = try? await summarizer().complete(system: "s", user: "x")
        XCTAssertNil(answer, "an empty summary would be saved")
    }

    func testARefusalWithNoTextIsAFailure() async throws {
        StubLLMServer.reset(replies: [(200, #"{"content":[],"stop_reason":"refusal"}"#)])
        do {
            _ = try await summarizer(style: .anthropicMessages).complete(system: "s", user: "x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refusal"), error.localizedDescription)
        }
    }

    func testAClassifierThatFailsFallsBackToGeneralAndSaysSo() async throws {
        StubLLMServer.reset(replies: [
            (500, "down"),
            apiReply(Replies.sections(["summary": ["s"]])),
            apiReply(Replies.review(["summary": ["s"]])),
        ])
        let outcome = try await SummaryPipeline(
            backend: APISummaryBackend(summarizer: summarizer(), label: "x"), redaction: true
        ).run(transcript: "words")
        XCTAssertEqual(outcome.report.scenario, "general")
        XCTAssertTrue(outcome.report.notices.joined().contains("couldn't be classified"), "\(outcome.report.notices)")
    }

    // MARK: Choosing a backend

    private var profile: LLMProfile {
        LLMProfile(id: "p1", name: "Mine", providerID: "custom", model: "m", baseURL: "https://llm.example.com/v1")
    }

    func testAskingForAnAPIProfileWithNoKeySaysSoAndOffersTheCLIs() async throws {
        var config = Config()
        config.llmRoute = .apiProfile
        config.llmProfiles = [profile]
        config.selectedLLMProfileID = "p1"
        try await withEnvironment("LLM_API_KEY", nil) {
            do {
                _ = try await SummaryRoute.backend(config: config)
                XCTFail("there's no key")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Mine"), error.localizedDescription)
            }
        }
    }

    func testFlagOverridesPickTheAPIEvenOnTheSubscriptionRoute() async throws {
        var config = Config()
        config.llmProfiles = [profile]
        config.selectedLLMProfileID = "p1"
        let overrides = SummaryRoute.APIOverrides(apiKeyFlag: fakeKey)
        let backend = try await SummaryRoute.backend(config: config, overrides: overrides)
        XCTAssertTrue(backend is APISummaryBackend)
        XCTAssertEqual(backend.label, "Mine")
    }

    /// Points the real route at fake CLIs through PATH. Only the choice is checked: the
    /// router it builds uses the real usage file, so no call may be made through it.
    private func backendChosen(config: Config, cliReady: Bool) async throws -> SummaryBackend {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        if cliReady {
            try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
            try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        }
        APIKeyStore.write(fakeKey, forProfile: "p1")
        return try await withEnvironment("LLM_API_KEY", nil) {
            // The fakes need /usr/bin for `env bash`. With no fakes, PATH holds nothing to find.
            try await withEnvironment("PATH", world.bin.path + (cliReady ? ":/usr/bin:/bin" : "")) {
                try await SummaryRoute.backend(config: config)
            }
        }
    }

    func testAReadyCLIIsUsedEvenWithAKeyedProfileSaved() async throws {
        var config = Config()
        config.llmProfiles = [profile]
        config.selectedLLMProfileID = "p1"
        let backend = try await backendChosen(config: config, cliReady: true)
        XCTAssertTrue(backend is CLISummaryBackend, "starting API billing is never the default")
    }

    func testNoCLIUsesTheSavedProfile() async throws {
        var config = Config()
        config.llmProfiles = [profile]
        config.selectedLLMProfileID = "p1"
        let backend = try await backendChosen(config: config, cliReady: false)
        XCTAssertTrue(backend is APISummaryBackend)
    }

    func testNoCLIAndNoProfileSaysWhy() async throws {
        do {
            _ = try await backendChosen(config: Config(), cliReady: false)
            XCTFail("there's nothing to run on")
        } catch let error as LLMRouter.RouterError {
            guard case .noCLI(let reasons) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(reasons.isEmpty)
        }
    }

    // MARK: Which protocol a profile speaks

    func testTheHostDecidesTheWireFormatForCustomProfiles() {
        let cases: [(String, String, LLMAPIStyle, ReasoningStyle)] = [
            ("https://api.anthropic.com/v1", "custom", .anthropicMessages, .anthropic),
            ("https://API.ANTHROPIC.COM/v1", "custom", .anthropicMessages, .anthropic),
            ("https://api.deepseek.com", "custom", .openAIChat, .thinking),
            ("https://api.openai.com/v1", "custom", .openAIChat, .openai),
            ("http://localhost:11434/v1", "ollama", .openAIChat, .none),
            ("https://internal.example.com/v1", "custom", .openAIChat, .none),
            ("not a url", "anthropic", .anthropicMessages, .anthropic),
            ("", "stale-provider", .openAIChat, .none),
        ]
        for (base, provider, api, reasoning) in cases {
            XCTAssertEqual(LLMProvider.apiStyle(baseURL: base, providerID: provider), api, base)
            XCTAssertEqual(LLMProvider.reasoningStyle(baseURL: base, providerID: provider), reasoning, base)
        }
    }

    func testAnOverrideBeatsWhatTheHostSuggests() {
        var profile = LLMProfile(name: "x", providerID: "custom", model: "m", baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(profile.effectiveReasoningStyle, .openai)
        profile.reasoningStyleOverride = ReasoningStyle.none
        XCTAssertEqual(profile.effectiveReasoningStyle, .none)
        XCTAssertFalse(profile.supportsReasoning)
    }
}

/// The transcript-to-report path, on fake CLIs.
final class SummaryPipelineAttackTests: GuardedTestCase {

    private var world: FakeCLIWorld!

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func pipeline(redaction: Bool = true) -> SummaryPipeline {
        SummaryPipeline(backend: CLISummaryBackend(router: world.router()), redaction: redaction)
    }

    /// The fake logs one line per argument line, so a prompt spans several entries.
    private func allArguments(of call: FakeCLIWorld.Call) -> String {
        call.args.joined(separator: "\n")
    }

    private func script(_ json: String, cli: CLIKind = .claude) -> FakeCLIWorld.Script {
        FakeCLIWorld.jsonScript(json, cli: cli)
    }

    private var sectionsReply: String { Replies.sections(["summary": ["notes"]]) }
    private var reviewReply: String { Replies.review(["summary": ["notes"]]) }

    /// The deep review's finding was about invented speech; this is invented meetings.
    /// A silent recording leaves an empty transcript, and nothing may summarize it.
    func testAnEmptyTranscriptIsNeverSentToAModel() async throws {
        try world.install(.claude, answers: [script(sectionsReply)])
        for transcript in ["", "\n", "   \n  "] {
            do {
                _ = try await pipeline().run(transcript: transcript)
                XCTFail("an empty transcript must stop")
            } catch let error as ReportError {
                XCTAssertEqual(error, .emptyTranscript)
            }
        }
        XCTAssertEqual(world.calls(.claude).count, 0, "this spends usage, and the model will invent a report")
    }

    func testAClassifierHittingAFullLimitMovesTheLaterStepsToo() async throws {
        try world.install(.claude, answers: [.init(stdout: "", exit: 1, stderr: "usage limit")])
        try world.install(
            .codex,
            answers: [
                script(Replies.classify("meeting"), cli: .codex), script(sectionsReply, cli: .codex),
                script(reviewReply, cli: .codex),
            ])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "notes")
        XCTAssertEqual(outcome.report.scenario, "meeting")
        XCTAssertEqual(world.calls(.claude).count, 1, "Claude isn't tried again")
        XCTAssertEqual(world.calls(.codex).count, 3, "classify, sections and review all ran on Codex")
        XCTAssertTrue(outcome.report.notices.joined().contains("Codex"))
        XCTAssertTrue(outcome.report.models.normal.contains("Codex"))
    }

    func testAClassifierFailureFallsBackToGeneralWithANotice() async throws {
        try world.install(
            .claude,
            answers: [
                .init(stdout: "", exit: 1, stderr: "model not found"), script(sectionsReply), script(reviewReply),
            ])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(outcome.report.scenario, "general")
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "notes")
        XCTAssertTrue(outcome.report.notices.joined().contains("couldn't be classified"), "\(outcome.report.notices)")
    }

    func testTheClassifiersScenarioPicksTheTemplateTheSectionsUse() async throws {
        try world.install(
            .claude,
            answers: [
                script(Replies.classify("therapy")), script(Replies.sections(["summary": ["s"]])),
                script(Replies.concepts([])), script(Replies.review(["summary": ["s"]])),
            ])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(outcome.report.scenario, "therapy")
        let sectionsCall = world.calls(.claude)[1]
        XCTAssertTrue(allArguments(of: sectionsCall).contains("Therapy session"))
        XCTAssertTrue(allArguments(of: sectionsCall).contains("Do not diagnose"))
    }

    /// The old classifier read the word "therapy" anywhere in a free-text answer, so "not therapy"
    /// picked therapy. The scenario is now a field from a JSON schema with an enum, and anything
    /// that isn't exactly a known name falls back. (The therapy-word parsing tests were dropped.)
    func testAScenarioFieldThatIsNotAKnownNameIsNotTrusted() async throws {
        try world.install(
            .claude,
            answers: [
                script(Replies.classify("meeting, not therapy")), script(sectionsReply), script(reviewReply),
            ])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(outcome.report.scenario, "general")
        XCTAssertFalse(outcome.report.notices.isEmpty)
    }

    func testTheClassifierSeesAtMostTheHeadAndASampleOfALongTranscript() async throws {
        try world.install(
            .claude, answers: [script(Replies.classify("meeting")), script(sectionsReply), script(reviewReply)])
        let lines = (0..<100).map {
            String(format: "[00:%02d:00] You: LINE-%03d-MARK ", $0 / 60 + 0, $0) + String(repeating: "word ", count: 18)
        }
        let long = lines.joined(separator: "\n")
        XCTAssertGreaterThan(long.count, 6000)
        _ = try await pipeline().run(transcript: long)

        let classify = world.calls(.claude)[0].stdin
        XCTAssertLessThan(classify.count, long.count * 3 / 5, "the classifier gets a sample, not everything")
        XCTAssertTrue(classify.contains("LINE-000-MARK"), "the head is there")
        XCTAssertTrue(classify.contains("LINE-099-MARK"), "the end is there")
        XCTAssertFalse(classify.contains("LINE-045-MARK"), "a line outside the head, middle and end is not")
        let sections = world.calls(.claude)[1].stdin
        XCTAssertTrue(sections.contains("LINE-045-MARK"), "the sections step gets it all")
        XCTAssertTrue(sections.contains("LINE-099-MARK"))
    }

    func testATranscriptWithNoValuesGetsNoTokenInstruction() async throws {
        try world.install(.claude, answers: [script(sectionsReply), script(reviewReply)])
        let outcome = try await pipeline().run(transcript: "nothing private", forcedScenario: "meeting")
        XCTAssertEqual(outcome.redactedValues, 0)
        XCTAssertFalse(
            outcome.report.notices.joined().contains("kept out of every request"),
            "nothing to add when nothing happened")
        for call in world.calls(.claude) {
            XCTAssertFalse(allArguments(of: call).contains("placeholder tokens"))
        }
    }

    func testRedactionOffLeavesTokenLookalikesInTheAnswerAlone() async throws {
        let reply = Replies.sections(["summary": ["See <EMAIL_1> in the doc"]])
        try world.install(
            .claude, answers: [script(reply), script(Replies.review(["summary": ["See <EMAIL_1> in the doc"]]))])
        let outcome = try await pipeline(redaction: false).run(transcript: "words", forcedScenario: "meeting")
        XCTAssertEqual(items(outcome.report, "summary").first?.text, "See <EMAIL_1> in the doc")
        XCTAssertEqual(outcome.flaggedTokens, [])
        XCTAssertFalse(outcome.report.notices.joined().contains("Couldn't restore"))
    }
}
