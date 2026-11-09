import XCTest

@testable import MeetingCaptureCore

/// M6 deep-review regressions: L2 (API error text), L4 (safePrefix), M1 and M2 (documented
/// behaviour), L1 (menu name in messages). All data is invented.
final class M6ReviewFindingTests: GuardedTestCase {

    // MARK: L2

    func testM6ReviewL2_scrubbedCapsAndRedactsProviderText() {
        let email = "dana.invented" + "@example.com"
        let body = "quoted " + email + " " + String(repeating: "x", count: 5000)
        let out = Summarizer.scrubbed(Data(body.utf8))
        XCTAssertLessThanOrEqual(out.count, 401)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertFalse(out.contains(email))
        XCTAssertTrue(out.contains("<EMAIL_1>"), out)
        XCTAssertEqual(Summarizer.scrubbed(Data("short".utf8)), "short")
        XCTAssertLessThanOrEqual(Summarizer.scrubbed(Data(body.utf8), limit: 50).count, 51)
    }

    func testM6ReviewL2_withoutQueryDropsQueryFragmentAndUserInfo() throws {
        let url = try XCTUnwrap(
            URL(string: "https://u" + ":p" + "@api.example.com/v1/chat/completions?key=FAKEKEY123#x"))
        let out = Summarizer.withoutQuery(url)
        XCTAssertFalse(out.contains("FAKEKEY123"))
        XCTAssertFalse(out.contains("u:p@"))
        XCTAssertFalse(out.contains("#"))
        XCTAssertFalse(out.contains("?"))
        XCTAssertTrue(out.contains("api.example.com"))
        XCTAssertTrue(out.contains("/v1/chat/completions"))
    }

    func testM6ReviewL2_apiErrorHasNoQueryKeyAndIsCapped() async throws {
        URLProtocol.registerClass(StubLLMServer.self)
        defer { URLProtocol.unregisterClass(StubLLMServer.self) }
        StubLLMServer.reset(replies: [(500, String(repeating: "oops ", count: 2000))])
        let s = Summarizer(
            baseURL: URL(string: "https://llm.example.com/v1?key=FAKEKEY12345678")!,
            apiKeyProvider: { "fake-key-for-tests" }, model: "fake-model", apiStyle: .openAIChat,
            reasoningStyle: .none, reasoningEffort: .off)
        do {
            _ = try await s.complete(system: "s", user: "u")
            XCTFail("a 500 must throw")
        } catch {
            let text = "\(error)"
            XCTAssertFalse(text.contains("FAKEKEY12345678"), text)
            XCTAssertLessThan(text.count, 900, "capped, not the whole 10,000-character body")
            XCTAssertTrue(text.contains("HTTP 500"))
        }
    }

    // MARK: L4

    /// The reviewer's string: two rules can match overlapping spans. Whatever the real
    /// rules match, the prefix must never end inside a matched value.
    func testM6ReviewL4_safePrefixNeverEndsInsideAMatchAtAnyCut() {
        let texts = [
            "AB12 CDEF GHIJ 12 3456 7890",
            "call +49 170 1234567 or mail dana.invented" + "@example.com about DE89 3704 0044 0532 0130 00 now",
            "ref GB82 WEST 1234 5698 7654 32 tel 555-123-4567 end",
            "x 4111 1111 1111 1111 y 123-45-6789 z",
        ]
        for text in texts {
            let tokens = Redactor.redact(text).tokens
            let ns = text as NSString
            var spans: [NSRange] = []
            for value in tokens.values {
                let r = ns.range(of: value)
                if r.location != NSNotFound { spans.append(r) }
            }
            for cut in 1...text.count {
                let prefix = Redactor.safePrefix(text, maxCharacters: cut)
                XCTAssertTrue(text.hasPrefix(prefix))
                let end = (prefix as NSString).length
                for r in spans {
                    XCTAssertFalse(
                        r.location < end && end < r.location + r.length,
                        "cut \(cut) of “\(text)” ends inside \(r): “\(prefix)”")
                }
            }
        }
    }

    // MARK: M2 (known limit, documented in README and SECURITY.md)

    /// Pins a known limit: a concept that contains a name the app doesn't know as a
    /// speaker is searchable. Only renamed speaker labels are protected (D-13).
    func testM6ReviewM2_aNonSpeakerNameInAConceptIsSearchableKnownLimit() {
        let concept = "Dana's attachment pattern"
        XCTAssertTrue(SummaryPipeline.isSearchableConcept(concept, speakers: ["You", "Speaker 1"]))
        XCTAssertFalse(SummaryPipeline.isSearchableConcept(concept, speakers: ["You", "Dana"]))
    }

    // MARK: L1

    func testM6ReviewL1_noUserFacingStringSaysLLMConfigurations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MeetingCaptureCore")
        for file in ["Summarize.swift", "SummaryPipeline.swift", "App.swift", "Config.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("LLM configurations"), "\(file) still says “LLM configurations”")
            XCTAssertTrue(file == "Config.swift" || text.contains("API configurations") || file == "App.swift", file)
        }
    }

    func testM6ReviewL1_missingKeyErrorsNameAPIConfigurations() async throws {
        let s = Summarizer(
            baseURL: URL(string: "https://llm.example.com/v1")!, apiKeyProvider: { nil }, model: "m",
            apiStyle: .openAIChat, reasoningStyle: .none, reasoningEffort: .off)
        do {
            _ = try await s.complete(system: "s", user: "u")
            XCTFail("no key must throw")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains("API configurations"), text)
            XCTAssertFalse(text.contains("LLM configurations"), text)
        }
    }
}

/// M6 review M1: with a past report's notes switch on and the group's context switch off,
/// the notes reach the context as written (documented), while the transcript is tokenized.
final class M6ReviewGroupNotesTests: GroupTestCase {

    func testM6ReviewM1_notesSwitchOnAndContextRedactionOffSendsNotesAsWritten() throws {
        let email = "dana.invented" + "@example.com"
        var on = ReportEdits()
        on.sendNotesToLLM = true
        try addRecording(
            "meeting_notes_on", hoursAgo: 7, report: simpleReport(topic: "TopicNotesOn"), edits: on,
            notes: "Follow up with \(email) on Friday")
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        let group = try makeGroup([recName, "meeting_notes_on"])
        try GroupStore.setRedactContext(group.id, false, globalRedaction: true, in: dir)

        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        XCTAssertFalse(context.redact, "the group's switch is off")
        XCTAssertTrue(context.text.contains("Follow up with"), context.text)
        XCTAssertTrue(context.text.contains(email), "documented: the notes go as written")

        let out = SummaryPipeline.redactTogether(
            transcript: "[00:00:01] You: write to \(email)", notes: nil, context: context.text,
            redaction: true, redactContext: context.redact)
        XCTAssertFalse(out.transcript.text.contains(email), "the transcript is tokenized")
        XCTAssertTrue(out.transcript.text.contains("<EMAIL_1>"))
        XCTAssertEqual(out.context, context.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(try XCTUnwrap(out.context).contains(email))
    }
}
