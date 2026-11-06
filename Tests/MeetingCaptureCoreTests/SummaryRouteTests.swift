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

    func testRedactedValuesStayOutOfEveryAPIRequestAndComeBackInTheAnswer() async throws {
        StubLLMServer.reset(replies: [(200, #"{"choices":[{"message":{"content":"meeting"}}]}"#), (200, openAIReply)])
        let pipeline = SummaryPipeline(
            backend: APISummaryBackend(summarizer: summarizer(), label: "x"), redaction: true)
        let outcome = try await pipeline.run(transcript: "[00:00:01] You: Send the contract to \(email), please.")

        XCTAssertEqual(StubLLMServer.seen.count, 2, "the classifier and the summary")
        for seen in StubLLMServer.seen {
            XCTAssertFalse(seen.body.contains(email), seen.body)
            XCTAssertFalse(seen.request.url?.absoluteString.contains(fakeKey) ?? true, "a key doesn't belong in a URL")
        }
        XCTAssertEqual(outcome.markdown, "Send it to \(email).")
    }

    // MARK: Wire shapes

    func testOpenAIRequestUsesBearerAuthAndAChatBody() async throws {
        StubLLMServer.reset(replies: [(200, openAIReply)])
        _ = try await summarizer().summarize(transcript: "words")
        let seen = try XCTUnwrap(StubLLMServer.seen.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeKey)")
        XCTAssertNil(seen.request.value(forHTTPHeaderField: "x-api-key"))
        let body = try json(seen.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "words")
    }

    func testAnthropicRequestUsesItsOwnHeaderAndHasNoTemperature() async throws {
        StubLLMServer.reset(replies: [(200, #"{"content":[{"type":"text","text":"ok"}]}"#)])
        let answer = try await summarizer(base: "https://api.anthropic.example/v1", style: .anthropicMessages)
            .summarize(transcript: "words")
        XCTAssertEqual(answer, "ok")
        let seen = try XCTUnwrap(StubLLMServer.seen.first)
        XCTAssertEqual(seen.request.url?.lastPathComponent, "messages")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-api-key"), fakeKey)
        XCTAssertNil(seen.request.value(forHTTPHeaderField: "Authorization"), "the key goes in one place")
        let body = try json(seen.body)
        XCTAssertNil(body["temperature"])
        XCTAssertNotNil(body["max_tokens"])
        XCTAssertNotNil(body["system"])
    }

    func testReasoningIsSentInTheShapeEachProviderReads() async throws {
        StubLLMServer.reset(replies: [(200, openAIReply)])
        _ = try await summarizer(reasoning: .thinking, effort: .medium).summarize(transcript: "x")
        _ = try await summarizer(reasoning: .thinking, effort: .off).summarize(transcript: "x")
        _ = try await summarizer(reasoning: .openai, effort: .high).summarize(transcript: "x")
        _ = try await summarizer(reasoning: .openai, effort: .off).summarize(transcript: "x")
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
            _ = try await keyless.summarize(transcript: "x")
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(StubLLMServer.seen.count, 0)
    }

    func testAnHTTPErrorSurfacesWithTheStatusAndNeverTheKey() async throws {
        StubLLMServer.reset(replies: [(429, "slow down")])
        do {
            _ = try await summarizer().summarize(transcript: "x")
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
            _ = try await summarizer().summarize(transcript: "x")
            XCTFail("expected a failure")
        } catch {
            message = error.localizedDescription
        }
        XCTAssertFalse(message.contains(email), message)
    }

    /// Summarize.swift's own comment says a reasoning model can leave `content` empty.
    func testAnEmptyAPIAnswerIsAFailureNotAnEmptySummary() async throws {
        StubLLMServer.reset(replies: [(200, #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#)])
        let answer = try? await summarizer().summarize(transcript: "x")
        XCTAssertNil(answer, "an empty summary would be saved")
    }

    func testARefusalWithNoTextIsAFailure() async throws {
        StubLLMServer.reset(replies: [(200, #"{"content":[],"stop_reason":"refusal"}"#)])
        do {
            _ = try await summarizer(style: .anthropicMessages).summarize(transcript: "x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refusal"), error.localizedDescription)
        }
    }

    func testAClassifierThatFailsFallsBackToMeeting() async throws {
        StubLLMServer.reset(replies: [(500, "down"), (200, openAIReply)])
        let outcome = try await SummaryPipeline(
            backend: APISummaryBackend(summarizer: summarizer(), label: "x"), redaction: true
        ).run(transcript: "words")
        XCTAssertEqual(outcome.style, .meeting)
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

/// The transcript-to-summary path, on fake CLIs.
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

    /// The deep review's finding was about invented speech; this is invented meetings.
    /// A silent recording leaves an empty transcript, and nothing may summarize it.
    func testAnEmptyTranscriptIsNeverSentToAModel() async throws {
        try world.install(
            .claude, answers: [.init(stdout: FakeCLIWorld.claudeOK("A productive meeting about nothing."))])
        for transcript in ["", "\n", "   \n  "] {
            _ = try? await pipeline().run(transcript: transcript)
        }
        XCTAssertEqual(world.calls(.claude).count, 0, "this spends usage, and the model will invent a summary")
    }

    func testAClassifierHittingAFullLimitMovesTheSummaryToo() async throws {
        try world.install(.claude, answers: [.init(stdout: "", exit: 1, stderr: "usage limit")])
        try world.install(
            .codex,
            answers: [.init(stdout: FakeCLIWorld.codexOK("meeting")), .init(stdout: FakeCLIWorld.codexOK("notes"))])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(outcome.markdown, "notes\n\n---\n> Note: \(outcome.notes[0])".isEmpty ? "" : "notes")
        XCTAssertEqual(world.calls(.claude).count, 1, "Claude isn't tried again")
        XCTAssertEqual(outcome.notes.count, 1)
        XCTAssertTrue(outcome.report.contains("Codex"))
    }

    func testAClassifierFailureFallsBackToAMeetingSummary() async throws {
        try world.install(
            .claude,
            answers: [
                .init(stdout: "", exit: 1, stderr: "model not found"), .init(stdout: FakeCLIWorld.claudeOK("notes")),
            ])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(outcome.style, .meeting)
        XCTAssertEqual(outcome.markdown, "notes")
    }

    func testTheClassifierPicksThePromptTheSummaryUses() async throws {
        try world.install(
            .claude,
            answers: [.init(stdout: FakeCLIWorld.claudeOK("Therapy.")), .init(stdout: FakeCLIWorld.claudeOK("notes"))])
        let outcome = try await pipeline().run(transcript: "words")
        XCTAssertEqual(outcome.style, .therapy)
        XCTAssertTrue(allArguments(of: world.calls(.claude)[1]).contains(Summarizer.systemPrompt(for: .therapy)))
    }

    /// The classifier is asked for one word, but a model can say more.
    func testAnAnswerSayingItIsNotTherapyIsNotTherapy() async throws {
        try world.install(
            .claude,
            answers: [
                .init(stdout: FakeCLIWorld.claudeOK("meeting, not therapy")),
                .init(stdout: FakeCLIWorld.claudeOK("notes")),
            ])
        let outcome = try await pipeline().run(transcript: "words")
        XCTExpectFailure(
            "BUG: unsure, low. The classifier checks contains(\"therapy\"), so \"meeting, not therapy\" picks the therapy prompt."
        )
        XCTAssertEqual(outcome.style, .meeting)
    }

    func testTheClassifierSeesAtMostTheStartOfTheTranscript() async throws {
        try world.install(
            .claude,
            answers: [.init(stdout: FakeCLIWorld.claudeOK("meeting")), .init(stdout: FakeCLIWorld.claudeOK("notes"))])
        let long = String(repeating: "x", count: 7000)
        _ = try await pipeline().run(transcript: long)
        XCTAssertEqual(world.calls(.claude)[0].stdin.count, 6000)
        XCTAssertEqual(world.calls(.claude)[1].stdin.count, 7000, "the summary gets it all")
    }

    func testATranscriptWithNoValuesGetsNoTokenInstruction() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK("notes"))])
        let outcome = try await pipeline().run(transcript: "nothing private", forcedStyle: .meeting)
        XCTAssertEqual(outcome.redactedValues, 0)
        XCTAssertEqual(outcome.report, "notes", "nothing to add when nothing happened")
        XCTAssertFalse(allArguments(of: world.calls(.claude)[0]).contains("placeholder tokens"))
    }

    func testRedactionOffLeavesTokenLookalikesInTheAnswerAlone() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK("See <EMAIL_1> in the doc"))])
        let outcome = try await pipeline(redaction: false).run(transcript: "words", forcedStyle: .meeting)
        XCTAssertEqual(outcome.markdown, "See <EMAIL_1> in the doc")
        XCTAssertEqual(outcome.flaggedTokens, [])
    }
}
