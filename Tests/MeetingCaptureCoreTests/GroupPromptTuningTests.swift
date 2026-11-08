import XCTest

@testable import MeetingCaptureCore

/// D-98 (2026-11-09): with group context the sections and review prompts ask for a follow-up's
/// earlier fact as its own item marked `earlier`; without context they say nothing of it.
final class GroupPromptTuningTests: GroupTestCase {

    private var template: ScenarioTemplate { ScenarioCatalog.builtIn.general }

    private func sections(_ earlier: Bool) -> String {
        SummaryPipeline.sectionsPrompt(template, language: "en", earlier: earlier)
    }
    private func review(_ earlier: Bool) -> String {
        SummaryPipeline.reviewPrompt(template, language: "en", earlier: earlier)
    }

    // MARK: 1. the new instructions with context

    func testD98SectionsPromptAsksForAnEarlierFactAsItsOwnMarkedItem() {
        let p = sections(true)
        XCTAssertTrue(p.contains("as its own item"))
        XCTAssertTrue(p.contains("\"source\": \"earlier\""))
        XCTAssertTrue(p.contains("Never mix an earlier fact into an item about what was said in this recording"))
        XCTAssertTrue(p.contains("a few at most"))
        XCTAssertTrue(p.contains("the transcript wins"))
    }

    func testD98ReviewPromptKeepsSplitsAndAddsEarlierItems() {
        let p = review(true)
        XCTAssertTrue(p.contains("\"source\": \"earlier\""))
        XCTAssertTrue(p.contains("Don't remove such an item or reword it"))
        XCTAssertTrue(p.contains("just because the transcript doesn't say it"))
        XCTAssertTrue(p.contains("take the earlier fact out of that item"))
        XCTAssertTrue(p.contains("add it as its own earlier item"))
        XCTAssertTrue(p.contains("as its own item"), "the shared rules reach the review too")
        XCTAssertTrue(p.contains("Never mix an earlier fact into an item about what was said in this recording"))
        XCTAssertTrue(p.contains("the transcript wins"))
        XCTAssertTrue(p.contains("doesn't contradict it"), "a contradiction still removes it")
    }

    // MARK: 2. no context

    func testD98WithoutContextNeitherPromptMentionsEarlier() {
        for p in [sections(false), review(false)] {
            XCTAssertFalse(p.lowercased().contains("earlier"))
        }
        let d1 = SummaryPipeline.sectionsPrompt(template, language: "en")
        let d2 = SummaryPipeline.reviewPrompt(template, language: "en")
        XCTAssertFalse(d1.lowercased().contains("earlier"), "off by default")
        XCTAssertFalse(d2.lowercased().contains("earlier"), "off by default")
        XCTAssertTrue(review(false).contains("remove what was invented"))
    }

    // MARK: 3. the example can't steer the live comparison

    func testD98PromptsShareNoContentWithTheLiveGroupFixtures() throws {
        let root = ReportFixtures.fixturesRoot.appendingPathComponent("live/group")
        let fixtures = try ["week1.txt", "week2.txt"].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
        let prompts = [sections(true), review(true)]
        for p in prompts {
            let lower = p.lowercased()
            for word in ["printer", "quickprint", "flyer", "card reader", "youth club", "book sale", "wifi", "hall"] {
                XCTAssertFalse(lower.contains(word), "prompt mentions \(word)")
            }
            XCTAssertNil(p.range(of: #"\b28\b"#, options: .regularExpression), "prompt has the number 28")
        }
        // Any run of 3 words taken from a fixture line must not appear in the prompt.
        let lines = fixtures.flatMap { $0.split(separator: "\n") }.map {
            $0.replacingOccurrences(of: #"^\[[^\]]*\] [^:]*: "#, with: "", options: .regularExpression)
                .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        for p in prompts {
            let text = p.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
            for words in lines where words.count >= 4 {
                for i in 0...(words.count - 4) {
                    let gram = words[i..<(i + 4)].joined(separator: " ")
                    XCTAssertFalse(text.contains(gram), "prompt repeats fixture text: \(gram)")
                }
            }
        }
    }

    // MARK: 4. through the pipeline

    func testD98PipelineCarriesTheLinesInSectionsAndReviewButNotClassify() async throws {
        try addRecording("meeting_past", hoursAgo: 5, report: simpleReport(topic: "TopicPast", text: "Past fact"))
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        let context = try XCTUnwrap(GroupContextBuilder.build(for: base))
        let b = echoBackend()
        _ = try await ReportFixtures.pipeline(b, redaction: true).run(transcript: transcriptText, context: context)
        for tier in [ModelTier.normal, .frontier] {
            let s = try XCTUnwrap(b.calls(tier).first).system
            XCTAssertTrue(s.contains("as its own item"), "\(tier)")
            XCTAssertTrue(s.contains("\"source\": \"earlier\""), "\(tier)")
            XCTAssertTrue(s.contains("Never mix an earlier fact"), "\(tier)")
        }
        XCTAssertTrue(try XCTUnwrap(b.calls(.frontier).first).system.contains("Don't remove such an item"))
        let classify = try XCTUnwrap(b.calls(.cheap).first).system
        XCTAssertFalse(classify.lowercased().contains("earlier"))
        XCTAssertFalse(classify.contains("as its own item"))
    }
}
