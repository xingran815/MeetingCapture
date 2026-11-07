import Foundation
import XCTest

@testable import MeetingCaptureCore

/// Recorded model replies, input transcripts and snapshots for the six scenarios,
/// all invented, in `Tests/Fixtures/reports/<scenario>/`.
enum ReportFixtures {
    static let scenarios = ["meeting", "therapy", "interview", "one_on_one", "lecture", "general"]

    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func folder(_ scenario: String) -> URL {
        fixturesRoot.appendingPathComponent("reports").appendingPathComponent(scenario)
    }

    static func read(_ scenario: String, _ file: String) throws -> String {
        try String(contentsOf: folder(scenario).appendingPathComponent(file), encoding: .utf8)
    }

    static func exists(_ scenario: String, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(scenario).appendingPathComponent(file).path)
    }

    /// Set `UPDATE_SNAPSHOTS=1` to rewrite `expected.html` and `expected.md`.
    static var updateSnapshots: Bool { ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] == "1" }

    /// 2027-01-15 08:00:00 UTC, the same clock `FakeCLIWorld` uses.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func assertSnapshot(
        _ actual: String, scenario: String, file: String, testFile: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = folder(scenario).appendingPathComponent(file)
        if updateSnapshots {
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail(
                "No snapshot at \(url.path). Run with UPDATE_SNAPSHOTS=1 to create it.", file: testFile, line: line)
        }
        if expected != actual {
            // Show the first differing line, not two pages of HTML.
            let a = actual.components(separatedBy: "\n")
            let e = expected.components(separatedBy: "\n")
            let i = zip(a, e).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, e.count)
            XCTFail(
                "\(scenario)/\(file) differs at line \(i + 1).\n expected: \(i < e.count ? e[i] : "(end)")\n   actual: \(i < a.count ? a[i] : "(end)")\nRun with UPDATE_SNAPSHOTS=1 to accept.",
                file: testFile, line: line)
        }
    }

    static func pipeline(_ backend: SummaryBackend, redaction: Bool = true, catalog: ScenarioCatalog = .builtIn)
        -> SummaryPipeline
    {
        var p = SummaryPipeline(backend: backend, redaction: redaction, catalog: catalog)
        p.now = { now }
        p.timeZone = utc
        return p
    }
}

/// Builders for the small JSON replies tests make up.
enum Replies {
    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func classify(
        _ scenario: String, topic: String = "A topic", language: String = "en", confidence: String = "sure"
    ) -> String {
        json(["scenario": scenario, "topic": topic, "language": language, "confidence": confidence])
    }

    /// `items` maps a section id to the item dictionaries (or plain texts) in it.
    static func item(
        _ text: String, speaker: String = "", owner: String = "", due: String = "", answer: String = "",
        quote: String = "", detail: String = "", confidence: String = "sure", reason: String = "",
        source: String = "transcript"
    ) -> [String: String] {
        [
            "text": text, "speaker": speaker, "owner": owner, "due": due, "answer": answer, "quote": quote,
            "detail": detail, "confidence": confidence, "reason": reason, "source": source,
        ]
    }

    static func sections(
        topic: String = "A topic", _ texts: [String: [String]], changes: [(String, String)]? = nil,
        suggestions: [(Int, String)]? = nil
    ) -> String {
        sectionsItems(topic: topic, texts.mapValues { $0.map { item($0) } }, changes: changes, suggestions: suggestions)
    }

    static func sectionsItems(
        topic: String = "A topic", _ items: [String: [[String: String]]], changes: [(String, String)]? = nil,
        suggestions: [(Int, String)]? = nil
    ) -> String {
        var object: [String: Any] = ["topic": topic, "sections": items]
        if let changes { object["changes"] = changes.map { ["what": $0.0, "why": $0.1] } }
        if let suggestions { object["transcriptSuggestions"] = suggestions.map { ["line": $0.0, "suggestion": $0.1] } }
        return json(object)
    }

    /// A review reply: the same shape plus `changes` and `transcriptSuggestions`.
    static func review(
        topic: String = "A topic", _ texts: [String: [String]], changes: [(String, String)] = [],
        suggestions: [(Int, String)] = []
    ) -> String {
        sections(topic: topic, texts, changes: changes, suggestions: suggestions)
    }

    static func concepts(_ list: [(name: String, explanation: String, sources: [(String, String)])]) -> String {
        json([
            "concepts": list.map {
                [
                    "name": $0.name, "explanation": $0.explanation,
                    "sources": $0.sources.map { ["title": $0.0, "url": $0.1] },
                ] as [String: Any]
            }
        ])
    }
}

/// A backend that answers in process, so pipeline logic is tested without a
/// process per call. Which step a call is: cheap is classify, normal is sections,
/// frontier is review; `searchConcepts` is the tools-on search.
final class ScriptedBackend: SummaryBackend {
    struct Call {
        let tier: ModelTier
        let system: String
        let input: String
        let schema: String
    }

    var calls: [Call] = []
    var searches: [[String]] = []
    var notes: [String] = []
    let label = "scripted"

    var onComplete: (Call) throws -> String
    /// Nil means this backend can't search, as the API backend can't.
    var onSearch: ([String]) throws -> String?

    init(
        onComplete: @escaping (Call) throws -> String = { _ in "{}" },
        onSearch: @escaping ([String]) throws -> String? = { _ in nil }
    ) {
        self.onComplete = onComplete
        self.onSearch = onSearch
    }

    static func model(_ tier: ModelTier) -> String {
        switch tier {
        case .cheap: return "Claude haiku"
        case .normal: return "Claude sonnet"
        case .frontier: return "Claude opus"
        }
    }

    func complete(tier: ModelTier, system: String, input: String, schema: String) async throws -> BackendReply {
        let call = Call(tier: tier, system: system, input: input, schema: schema)
        calls.append(call)
        return BackendReply(text: try onComplete(call), model: Self.model(tier))
    }

    func searchConcepts(_ concepts: [String], schema: String) async throws -> BackendReply? {
        searches.append(concepts)
        guard let text = try onSearch(concepts) else { return nil }
        return BackendReply(text: text, model: Self.model(.normal))
    }

    func calls(_ tier: ModelTier) -> [Call] { calls.filter { $0.tier == tier } }

    /// Replies from the recorded files of one scenario.
    static func fixture(_ scenario: String) throws -> ScriptedBackend {
        let classify = try ReportFixtures.read(scenario, "classify.json")
        let sections = try ReportFixtures.read(scenario, "sections.json")
        let review = try ReportFixtures.read(scenario, "review.json")
        let concepts =
            ReportFixtures.exists(scenario, "concepts.json")
            ? try ReportFixtures.read(scenario, "concepts.json") : nil
        return ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return classify
                case .normal: return sections
                case .frontier: return review
                }
            },
            onSearch: { _ in concepts })
    }
}

extension ScriptedBackend {
    /// The recorded replies, except that one step throws.
    static func fixture(_ scenario: String, failing tier: ModelTier) throws -> ScriptedBackend {
        let base = try fixture(scenario)
        let inner = base.onComplete
        base.onComplete = { call in
            if call.tier == tier { throw StepFailure() }
            return try inner(call)
        }
        return base
    }
}

struct StepFailure: Error, LocalizedError {
    var errorDescription: String? { "the step failed on purpose" }
}

/// A fake-CLI world loaded with one scenario's recorded replies, in call order.
extension FakeCLIWorld {
    func installFixture(_ scenario: String, cli: CLIKind = .claude) throws {
        var replies = [
            try ReportFixtures.read(scenario, "classify.json"),
            try ReportFixtures.read(scenario, "sections.json"),
        ]
        if ReportFixtures.exists(scenario, "concepts.json") {
            replies.append(try ReportFixtures.read(scenario, "concepts.json"))
        }
        replies.append(try ReportFixtures.read(scenario, "review.json"))
        try install(cli, answers: replies.map { FakeCLIWorld.jsonScript($0, cli: cli) })
    }
}

/// Everything a report shows as text, for tests that look for a string anywhere in it.
func allText(_ report: Report) -> String {
    var parts = [report.topic, report.scenarioTitle]
    parts += report.notices
    for s in report.sections {
        parts += [s.title, s.note ?? ""]
        for i in s.items {
            parts += [i.text, i.speaker, i.owner, i.due, i.answer, i.quote, i.detail, i.reason].compactMap { $0 }
            parts += (i.sources ?? []).flatMap { [$0.title, $0.url] }
        }
    }
    parts += report.reviewChanges.flatMap { [$0.what, $0.why] }
    parts += report.transcript.flatMap { [$0.speaker, $0.text, $0.suggestion ?? ""] }
    return parts.joined(separator: "\n")
}

func items(_ report: Report, _ sectionID: String) -> [Report.Item] {
    report.sections.first { $0.id == sectionID }?.items ?? []
}

/// Text that must never become markup, and the checks that prove it did not.
enum XSS {
    static let payloads = [
        "<script>alert(1)</script>",
        "<img src=x onerror=alert(2)>",
        "\"><svg onload=alert(3)>",
        "'><iframe src=javascript:alert(4)>",
        "</script><script>alert(5)</script>",
        "<a href=\"javascript:alert(6)\">click</a>",
        "<b onmouseover=alert(7)>x</b>",
        "&lt;already&gt; & \"quotes\" 'single'",
        "<script>alert(8)</script> topic",
        "<details open ontoggle=alert(9)>",
        "<style>*{display:none}</style>",
        "<meta http-equiv=refresh content=0;url=javascript:alert(10)>",
        "<input autofocus onfocus=alert(11)>",
    ]

    /// Every one of these must fail `safeURL`.
    static let badURLs = [
        "javascript:alert(1)", "JAVASCRIPT:alert(1)", " javascript:alert(1)", "\tjavascript:alert(1)",
        "java\nscript:alert(1)", "data:text/html,<script>alert(1)</script>", "DATA:text/html;base64,PHNjcmlwdD4=",
        "vbscript:msgbox(1)", "file:///etc/passwd", "ftp://example.com/x", "//evil.example.com/x",
        "/relative/path", "https://", "http:///nohost", "https://exa mple.com/x", "mailto:a@example.com",
        "about:blank", "blob:https://example.com/uuid", "https:javascript:alert(1)", "",
    ]

    private static let allowedTags: Set<String> = [
        "html", "head", "meta", "title", "style", "script", "body", "header", "p", "h1", "h2", "h3", "ul", "ol", "li",
        "nav", "a", "main", "section", "div", "span", "details", "summary", "footer", "q", "br", "input", "article",
        "dl", "dt", "dd", "strong",
    ]

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map {
                m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
            }
        }
    }

    /// No markup but the renderer's own, one script block, links only to http(s) or the page itself.
    static func assertInert(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            html.components(separatedBy: "<script").count - 1, 1, "exactly one script block", file: file, line: line)
        XCTAssertEqual(html.components(separatedBy: "</script").count - 1, 1, file: file, line: line)
        XCTAssertTrue(
            html.contains("http-equiv=\"Content-Security-Policy\""), "the CSP meta is there", file: file, line: line)
        XCTAssertTrue(html.contains("default-src 'none'"), file: file, line: line)

        // Take out the page's own style and script, then every tag left must be one the renderer writes.
        var rest = html
        for tag in ["style", "script"] {
            if let open = rest.range(of: "<\(tag)>"), let close = rest.range(of: "</\(tag)>"),
                open.upperBound <= close.lowerBound
            {
                rest.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        let tags = Set(matches("<([A-Za-z][A-Za-z0-9]*)", in: rest).map { $0[1].lowercased() })
        XCTAssertTrue(
            tags.isSubset(of: allowedTags), "unexpected tags: \(tags.subtracting(allowedTags).sorted())", file: file,
            line: line)

        // No event handler or src attribute inside any tag.
        XCTAssertTrue(
            matches("<[A-Za-z][^>]*\\son[a-z]+\\s*=", in: rest).isEmpty, "an event handler attribute", file: file,
            line: line)
        XCTAssertTrue(
            matches("<[A-Za-z][^>]*\\s(src|srcset|action|formaction|style)\\s*=", in: rest).isEmpty,
            "a src, action or style attribute", file: file, line: line)

        // Every href goes to http(s) or an anchor on the page.
        for m in matches("href\\s*=\\s*\"([^\"]*)\"", in: rest) {
            let target = m[1]
            let lower = target.lowercased()
            let ok =
                lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("#s-")
                || lower == "#transcript"
            XCTAssertTrue(ok, "href to \(target)", file: file, line: line)
        }
        XCTAssertTrue(
            matches("<[A-Za-z][^>]*\\shref\\s*=\\s*[^\"\\s]", in: rest).isEmpty, "an unquoted href", file: file,
            line: line)
        // Nothing fetched from outside the page.
        XCTAssertFalse(rest.contains("@import"), file: file, line: line)
        XCTAssertFalse(rest.lowercased().contains("<link"), file: file, line: line)
    }
}
