import XCTest

@testable import MeetingCaptureCore

/// Step 5 of spec 04: JSON in, HTML out, no model. Escaping, links, the page's own
/// markup, the markdown and terminal forms.
final class ReportRendererTests: XCTestCase {

    /// Every text field set to something hostile, in every section kind.
    private func hostileReport() -> Report {
        let p = XSS.payloads
        func item(_ n: Int) -> Report.Item {
            Report.Item(
                text: p[n % p.count], speaker: p[(n + 1) % p.count], owner: p[(n + 2) % p.count],
                due: p[(n + 3) % p.count], answer: p[(n + 4) % p.count], quote: p[(n + 5) % p.count],
                detail: p[(n + 6) % p.count], confidence: "unsure", reason: p[(n + 7) % p.count], source: "ai",
                sources: XSS.badURLs.map { Report.Link(title: p[n % p.count], url: $0) }
                    + [Report.Link(title: p[0], url: "https://example.org/ok?a=1&b=<2>")])
        }
        let sections = SectionKind.allCases.enumerated().map { i, kind in
            Report.Section(
                id: "id\(i)\"><script>alert(1)</script>", title: p[i % p.count], kind: kind, note: p[(i + 3) % p.count],
                items: [item(i), item(i + 5)])
        }
        return Report(
            topic: p[0], scenario: "meeting", scenarioTitle: p[1], createdAt: "2027-01-15T08:00:00Z\"><script>",
            durationSeconds: 125, language: "en\"><script>alert(1)</script>",
            models: .init(cheap: p[2], normal: p[3], frontier: p[4]), reviewed: false, notices: p,
            sections: sections, reviewChanges: p.map { Report.Change(what: $0, why: $0) },
            transcript: p.enumerated().map { i, text in
                TranscriptEntry(start: Double(i), end: Double(i + 1), speaker: text, text: text, suggestion: text)
            })
    }

    func testEveryFieldOfAHostileReportRendersInert() {
        let html = ReportRenderer.html(hostileReport())
        XSS.assertInert(html)
        for payload in XSS.payloads.prefix(7) {
            XCTAssertFalse(html.contains(payload), "raw: \(payload)")
            XCTAssertTrue(html.contains(ReportRenderer.escape(payload)), "escaped: \(payload)")
        }
    }

    func testTheContentSecurityPolicyBlocksEverythingExternal() {
        let html = ReportRenderer.html(hostileReport())
        let csp =
            "default-src 'none'; style-src 'unsafe-inline'; script-src '\(ReportRenderer.scriptHash)'; img-src data:; base-uri 'none'; form-action 'none'"
        XCTAssertTrue(html.contains("<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"))
        XCTAssertTrue(html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        let head = html.components(separatedBy: "</head>")[0]
        XCTAssertTrue(head.contains("<meta charset=\"utf-8\">"))
        XCTAssertFalse(head.contains("connect-src"), "default-src 'none' already covers it")
    }

    func testThePageNeedsNothingFromOutside() async throws {
        let outcome = try await ReportFixtures.pipeline(try ScriptedBackend.fixture("meeting"))
            .run(transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        let html = ReportRenderer.html(outcome.report)
        for needle in [
            "<link", "@import", "src=\"http", "url(http", "<img", "<iframe", "<form", "fetch(", "XMLHttpRequest",
        ] {
            XCTAssertFalse(html.contains(needle), needle)
        }
        XCTAssertTrue(html.contains("prefers-color-scheme:dark"), "works in dark mode")
        XCTAssertTrue(html.contains("@media print"), "prints cleanly")
    }

    func testEscapeHandlesEveryMarkupCharacterAndNul() {
        XCTAssertEqual(
            ReportRenderer.escape("<a href=\"x\" title='y'>&amp;</a>"),
            "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;amp;&lt;/a&gt;")
        XCTAssertEqual(ReportRenderer.escape("a\u{0}b"), "a\u{FFFD}b")
        XCTAssertEqual(ReportRenderer.escape("季度规划 — ünï 🎉"), "季度规划 — ünï 🎉")
        XCTAssertEqual(ReportRenderer.escape(""), "")
    }

    func testOnlyHttpAndHttpsLinksBecomeLinks() {
        for good in [
            "https://example.org/a?b=c#d", "http://example.org", "HTTPS://EXAMPLE.org/Path",
            "  https://example.org/x  ",
        ] {
            XCTAssertNotNil(ReportRenderer.safeURL(good), good)
        }
        for bad in XSS.badURLs { XCTAssertNil(ReportRenderer.safeURL(bad), bad) }
    }

    func testAnUnsafeLinkIsShownAsTextWithANoteAndNeverAnHref() {
        for bad in XSS.badURLs {
            let link = ReportRenderer.linkHTML(Report.Link(title: "Title <b>", url: bad))
            XCTAssertFalse(link.contains("<a "), bad)
            XCTAssertFalse(link.contains("href"), bad)
            XCTAssertTrue(link.contains("link not shown"), bad)
            XCTAssertTrue(link.contains("Title &lt;b&gt;"))
        }
        let good = ReportRenderer.linkHTML(Report.Link(title: "T", url: "https://example.org/x"))
        XCTAssertTrue(good.contains("href=\"https://example.org/x\""))
        XCTAssertTrue(good.contains("rel=\"noopener noreferrer nofollow\""))
    }

    func testAURLWithAQuoteCannotBreakOutOfTheHrefAttribute() {
        let html = ReportRenderer.linkHTML(
            Report.Link(title: "t", url: "https://example.org/\" onmouseover=\"alert(1)"))
        XCTAssertFalse(html.contains("\" onmouseover"), html)
        XCTAssertFalse(html.contains("onmouseover=\"alert"), html)
        if html.contains("<a ") {
            let href = html.components(separatedBy: "href=\"")[1].components(separatedBy: "\"")[0]
            XCTAssertFalse(href.contains(" "), "the whole URL stayed inside the attribute: \(href)")
        }
    }

    func testUnsureItemsShowTheMarkAndReasonAndAIItemsAreSeparate() {
        let report = Report(
            topic: "t", scenario: "meeting", scenarioTitle: "M", createdAt: "", durationSeconds: 0, language: "",
            models: .init(), reviewed: true, notices: [],
            sections: [
                Report.Section(
                    id: "a", title: "A", kind: .bullets, note: nil,
                    items: [
                        Report.Item(text: "said", confidence: "sure", source: "transcript"),
                        Report.Item(
                            text: "doubtful", confidence: "UNSURE", reason: "The audio was unclear", source: "ai"),
                        Report.Item(text: "doubtful, no reason", confidence: "unsure"),
                    ]),
                Report.Section(
                    id: "q", title: "Q", kind: .qa, note: nil, items: [Report.Item(text: "why?", answer: "")]),
                Report.Section(id: "e", title: "E", kind: .actions, note: nil, items: []),
            ], reviewChanges: [], transcript: [])
        let html = ReportRenderer.html(report)
        XCTAssertTrue(html.contains("<span class=\"mark\">Unsure</span> The audio was unclear"))
        XCTAssertTrue(html.contains("<span class=\"mark\">Unsure</span> no reason given"))
        XCTAssertTrue(html.contains("<li class=\"ai unsure\">doubtful"))
        XCTAssertTrue(html.contains("<li>said</li>"), "an item that was said carries no AI styling")
        XCTAssertTrue(
            html.contains("<span class=\"badge\">AI</span> I don&#39;t know."),
            "an empty answer is shown as not knowing")
        XCTAssertTrue(html.contains("Nothing for this section."))
        XCTAssertFalse(html.contains("class=\"banner\""))
    }

    func testTheHeaderAndLanguageAreSetFromTheReport() async throws {
        let outcome = try await ReportFixtures.pipeline(try ScriptedBackend.fixture("lecture"))
            .run(transcript: try ReportFixtures.read("lecture", "transcript.txt"))
        let html = ReportRenderer.html(outcome.report)
        XCTAssertTrue(html.contains("<html lang=\"en\">"))
        XCTAssertTrue(html.contains("<title>Gradient descent basics</title>"))
        XCTAssertTrue(ReportRenderer.metaLine(outcome.report).hasPrefix("2027-01-15 08:00 · about 00:03:55"))
    }

    // MARK: Markdown

    func testMarkdownKeepsLinkSafetyAndFlattensFieldsToOneLine() {
        var report = hostileReport()
        report.reviewed = true
        report.sections = [
            Report.Section(
                id: "c", title: "Concepts", kind: .concepts, note: nil,
                items: [
                    Report.Item(
                        text: "a\n## injected heading", answer: "x\n- fake bullet", quote: "q\nline",
                        sources: XSS.badURLs.map { Report.Link(title: "t", url: $0) } + [
                            Report.Link(title: "ok", url: "https://example.org/ok")
                        ])
                ]),
            Report.Section(
                id: "b", title: "Bullets", kind: .bullets, note: nil,
                items: [
                    Report.Item(text: "first\n# Heading in the middle", speaker: "Sp\nlit")
                ]),
        ]
        let md = ReportRenderer.markdown(report)
        XCTAssertFalse(md.lowercased().contains("](javascript:"))
        XCTAssertFalse(md.lowercased().contains("](data:"))
        XCTAssertFalse(md.lowercased().contains("](vbscript:"))
        XCTAssertTrue(md.contains("](https://example.org/ok)"))
        XCTAssertFalse(md.contains("\n## injected heading"), "a heading can't be added from inside an item")
        XCTAssertFalse(md.contains("\n# Heading in the middle"))
    }

    func testMarkdownShowsDoubtAndTheAIAnswer() {
        let report = Report(
            topic: "T", scenario: "meeting", scenarioTitle: "M", createdAt: "2027-01-15T08:00:00Z", durationSeconds: 0,
            language: "", models: .init(cheap: "c", normal: "n", frontier: "f"), reviewed: true, notices: ["a notice"],
            sections: [
                Report.Section(
                    id: "q", title: "Q", kind: .qa, note: "Note line",
                    items: [
                        Report.Item(text: "why?", answer: "", confidence: "unsure", reason: "no data")
                    ]),
                Report.Section(
                    id: "a", title: "A", kind: .actions, note: nil,
                    items: [
                        Report.Item(text: "do it", owner: "Pat", due: "Friday")
                    ]),
                Report.Section(id: "e", title: "E", kind: .bullets, note: nil, items: []),
            ], reviewChanges: [Report.Change(what: "w", why: "y")], transcript: [])
        let md = ReportRenderer.markdown(report)
        XCTAssertTrue(md.hasPrefix("# T\n"))
        XCTAssertTrue(md.contains("_Note line_"))
        XCTAssertTrue(md.contains("AI: I don't know."))
        XCTAssertTrue(md.contains("_(unsure: no data)_"))
        XCTAssertTrue(md.contains("- [ ] do it (owner: Pat) (due: Friday)"))
        XCTAssertTrue(md.contains("None."))
        XCTAssertTrue(md.contains("- w — y"))
        XCTAssertTrue(md.contains("> Note: a notice"))
        XCTAssertTrue(md.contains("classify: c, sections: n, review: f"))
        XCTAssertFalse(md.contains("Not reviewed"))
    }

    // MARK: Terminal

    func testTheTerminalSummaryStripsControlCharactersFromModelText() {
        let esc = "\u{1B}"
        let bad = "\(esc)[2J\(esc)]0;owned\u{07}\u{8}\u{9B}31mred\r\u{7F}end"
        let report = Report(
            topic: "Topic \(bad)", scenario: "meeting", scenarioTitle: "M", createdAt: "", durationSeconds: 0,
            language: "", models: .init(), reviewed: true, notices: ["notice \(bad)"],
            sections: [
                Report.Section(
                    id: "a", title: "A", kind: .bullets, note: nil,
                    items: [
                        Report.Item(
                            text: "text \(bad)", speaker: "sp \(bad)", owner: "o \(bad)", due: "d \(bad)",
                            answer: "a \(bad)", confidence: "unsure", reason: "r \(bad)")
                    ]),
                Report.Section(
                    id: "q", title: "Q", kind: .qa, note: nil,
                    items: [Report.Item(text: "q \(bad)", answer: "a \(bad)")]),
            ], reviewChanges: [], transcript: [TranscriptEntry(start: 1, end: 2, speaker: "s \(bad)", text: "t \(bad)")]
        )
        let terminal = ReportRenderer.terminalSummary(report) + ReportConsole.text(report, showTranscript: true)
        let forbidden = terminal.unicodeScalars.filter { $0 != "\n" && CharacterSet.controlCharacters.contains($0) }
        XCTAssertTrue(
            forbidden.isEmpty, "control characters reach the terminal: \(forbidden.map { String($0.value, radix: 16) })"
        )
    }

    func testTerminalSafeKeepsTextAndNewlines() {
        XCTAssertEqual(ReportRenderer.terminalSafe("季度 plan\nnext — ünï 🎉"), "季度 plan\nnext — ünï 🎉")
        XCTAssertEqual(ReportRenderer.terminalSafe("a\u{1B}[31mb\tc"), "a[31mbc")
    }

    func testTheTerminalSummaryShowsEverythingInOrderWithMarks() async throws {
        let outcome = try await ReportFixtures.pipeline(try ScriptedBackend.fixture("meeting"))
            .run(transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        let text = ReportConsole.text(outcome.report, showTranscript: true)
        let transcript = try XCTUnwrap(text.range(of: "──── transcript"))
        let summary = try XCTUnwrap(text.range(of: "──── summary"))
        XCTAssertLessThan(transcript.lowerBound, summary.lowerBound, "the transcript comes first, then the summary")
        XCTAssertTrue(text.contains("[00:00:05] You: Okay, thanks everyone"))
        XCTAssertTrue(text.contains("[AI]"))
        XCTAssertTrue(text.contains("? unsure:"))
        XCTAssertTrue(text.contains("I don't know"))
        XCTAssertFalse(ReportConsole.text(outcome.report, showTranscript: false).contains("──── transcript"))
    }

    // MARK: Codable and files

    func testAReportEncodesAndDecodesToTheSameReport() async throws {
        let outcome = try await ReportFixtures.pipeline(try ScriptedBackend.fixture("therapy"))
            .run(transcript: try ReportFixtures.read("therapy", "transcript.txt"))
        let data = try JSONEncoder().encode(outcome.report)
        let back = try JSONDecoder().decode(Report.self, from: data)
        XCTAssertEqual(back, outcome.report)
        XCTAssertEqual(back.schemaVersion, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in [
            "schemaVersion", "topic", "scenario", "createdAt", "durationSeconds", "models", "reviewed", "notices",
            "sections", "transcript",
        ] {
            XCTAssertNotNil(object[key], key)
        }
    }

    func testAnItemWithOnlySomeFieldsStillDecodes() throws {
        let json =
            #"{"id":"a","title":"A","kind":"bullets","items":[{"text":"only text"},{"answer":"only answer","sources":[{"title":"t","url":"https://example.org"}]}]}"#
        let section = try JSONDecoder().decode(Report.Section.self, from: Data(json.utf8))
        XCTAssertEqual(section.items.count, 2)
        XCTAssertNil(section.items[0].speaker)
        XCTAssertEqual(section.items[1].sources?.first?.url, "https://example.org")
        XCTAssertNil(section.note)
    }

    func testWritingTheFilesNextToTheTranscriptNeverTouchesTheTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("meeting.txt")
        let transcript = try ReportFixtures.read("meeting", "transcript.txt")
        try transcript.write(to: source, atomically: true, encoding: .utf8)
        let outcome = try await ReportFixtures.pipeline(try ScriptedBackend.fixture("meeting")).run(
            transcript: transcript)

        let first = try ReportFiles.write(outcome.report, nextTo: source, date: ReportFixtures.now)
        XCTAssertEqual(first.markdown.lastPathComponent, "meeting.md")
        XCTAssertEqual(first.json.lastPathComponent, "meeting.report.json")
        XCTAssertTrue(
            first.html.lastPathComponent.hasSuffix("_Weekly-platform-sync.html"), first.html.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), transcript, "the transcript is as it was")
        let decoded = try JSONDecoder().decode(Report.self, from: Data(contentsOf: first.json))
        XCTAssertEqual(decoded, outcome.report)
        XCTAssertEqual(try String(contentsOf: first.html, encoding: .utf8), ReportRenderer.html(outcome.report))

        // A second report the same second keeps the first page.
        let second = try ReportFiles.write(outcome.report, nextTo: source, date: ReportFixtures.now)
        XCTAssertNotEqual(first.html, second.html)
        XCTAssertTrue(
            second.html.lastPathComponent.hasSuffix("_Weekly-platform-sync_2.html"), second.html.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.html.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), transcript)
    }
}

final class ReportFileNameTests: XCTestCase {

    func testChineseLettersAreKept() {
        XCTAssertEqual(ReportFileName.slug("季度规划会议"), "季度规划会议")
        XCTAssertEqual(ReportFileName.slug("项目 Kickoff 会议"), "项目-Kickoff-会议")
        XCTAssertEqual(ReportFileName.slug("Weekly platform sync"), "Weekly-platform-sync")
        XCTAssertEqual(ReportFileName.slug("Café Müller 2027"), "Café-Müller-2027")
    }

    func testSlashesDotsAndShellCharactersAreDropped() {
        XCTAssertEqual(ReportFileName.slug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ReportFileName.slug("a/b\\c"), "a-b-c")
        XCTAssertEqual(ReportFileName.slug("$(rm -rf ~); `ls` | cat > x"), "rm-rf-ls-cat-x")
        XCTAssertEqual(ReportFileName.slug("a&b;c'd\"e*f?g<h>i"), "a-b-c-d-e-f-g-h-i")
        XCTAssertEqual(ReportFileName.slug("a\nb\tc\u{0}d"), "a-b-c-d")
        XCTAssertEqual(ReportFileName.slug("\u{202E}txt.exe"), "txt-exe", "no right-to-left override in a file name")
        for hostile in ["../../x", "a/b", "$(x)", "`x`", "~root", "-rf", ".hidden", "a:b"] {
            let slug = ReportFileName.slug(hostile)
            XCTAssertFalse(slug.hasPrefix("-") || slug.hasPrefix("."), hostile)
            XCTAssertTrue(slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, "\(hostile) → \(slug)")
        }
    }

    func testEmojiAreDropped() {
        XCTAssertEqual(ReportFileName.slug("🎉 Launch 🚀 party"), "Launch-party")
        XCTAssertEqual(ReportFileName.slug("👍👍👍"), "report")
        XCTAssertEqual(
            ReportFileName.slug("plan 👨\u{200D}👩\u{200D}👧 family"), "plan-family", "a ZWJ sequence goes whole")
    }

    /// BUG candidate: a keycap emoji is a digit plus two combining marks, and the "word
    /// character" test passes each scalar, so `1\u{FE0F}\u{20E3}` stays in the file name.
    func testAKeycapEmojiIsNotKeptInTheName() {
        let slug = ReportFileName.slug("Q3 1\u{FE0F}\u{20E3} plan")
        XCTAssertFalse(slug.unicodeScalars.contains { $0.value == 0x20E3 || $0.value == 0xFE0F }, slug)
    }

    func testLeadingAndTrailingJunkIsTrimmed() {
        XCTAssertEqual(ReportFileName.slug("---  ..hi!!  ---"), "hi")
        XCTAssertEqual(ReportFileName.slug("  spaced out  "), "spaced-out")
        XCTAssertEqual(ReportFileName.slug("a   b"), "a-b", "a run of junk is one dash")
    }

    func testNothingLeftMeansReport() {
        for empty in ["", "   ", "///", "..", "🎉", "!!!", "\n\t"] {
            XCTAssertEqual(ReportFileName.slug(empty), "report", empty)
        }
    }

    func testVeryLongTopicsAreCutToFortyCharacters() {
        XCTAssertLessThanOrEqual(ReportFileName.slug(String(repeating: "abc ", count: 100)).count, 40)
        XCTAssertLessThanOrEqual(ReportFileName.slug(String(repeating: "规", count: 300)).count, 40)
        XCTAssertEqual(ReportFileName.slug(String(repeating: "规", count: 300)).count, 40)
        let cutAtASpace = ReportFileName.slug(
            String(repeating: "a", count: 39) + " " + String(repeating: "b", count: 20))
        XCTAssertEqual(cutAtASpace, String(repeating: "a", count: 39), "no dash left dangling at the cut")
        let name = ReportFileName.name(
            topic: String(repeating: "规划", count: 200), date: ReportFixtures.now, timeZone: ReportFixtures.utc)
        XCTAssertLessThan(name.utf8.count, 255, "a legal file name even in bytes")
    }

    func testCombiningMarksAreNormalised() {
        XCTAssertEqual(ReportFileName.slug("Cafe\u{301}"), "Café")
    }

    func testTheNameStartsWithTheTimestampInTheGivenZone() {
        XCTAssertEqual(
            ReportFileName.name(topic: "Weekly sync", date: ReportFixtures.now, timeZone: ReportFixtures.utc),
            "20270115_080000_Weekly-sync.html")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ReportFileName.stamp(ReportFixtures.now, timeZone: tokyo), "20270115_170000")
        XCTAssertEqual(
            ReportFileName.name(topic: "", date: ReportFixtures.now, timeZone: ReportFixtures.utc),
            "20270115_080000_report.html")
    }

    func testACollisionGetsASuffixAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = ReportFileName.name(topic: "Sync", date: ReportFixtures.now)
        var seen: [String] = []
        for _ in 0..<4 {
            let url = ReportFileName.freeURL(in: dir, topic: "Sync", date: ReportFixtures.now)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            seen.append(url.lastPathComponent)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let stem = String(base.dropLast(5))
        XCTAssertEqual(seen, [base, "\(stem)_2.html", "\(stem)_3.html", "\(stem)_4.html"])
    }

    func testAHostileTopicStaysInsideTheFolder() {
        let dir = URL(fileURLWithPath: "/tmp/some/folder")
        for topic in ["../../../etc/cron.d/x", "/absolute/path", "~/Desktop/x", "a/../../b"] {
            let url = ReportFileName.freeURL(in: dir, topic: topic, date: ReportFixtures.now)
            XCTAssertEqual(url.deletingLastPathComponent().path, dir.path, topic)
            XCTAssertFalse(url.lastPathComponent.contains("/"))
        }
    }
}

final class TranscriptParserTests: XCTestCase {

    func testItReadsWhatSpeakerLabelsWrites() {
        let segments = [
            LabelledSegment(start: 4, end: 9, speaker: "You", text: "Thanks for joining."),
            LabelledSegment(
                start: 11.9, end: 20, speaker: "Speaker 1", text: "Note: the plan is ready. See you at 10:30."),
            LabelledSegment(start: 3725, end: 3730, speaker: "小雨", text: "你好，世界"),
            LabelledSegment(start: 3726, end: 3727, speaker: "Dr. Lee Smith", text: "Hello"),
        ]
        let parsed = TranscriptParser.parse(SpeakerLabels.format(segments))
        XCTAssertEqual(parsed.map(\.speaker), ["You", "Speaker 1", "小雨", "Dr. Lee Smith"])
        XCTAssertEqual(parsed.map(\.start), [4, 11, 3725, 3726])
        XCTAssertEqual(parsed.map(\.text), segments.map(\.text))
        XCTAssertEqual(parsed[0].end, 11, "a line ends where the next begins")
        XCTAssertEqual(parsed.last?.end, 3726)
    }

    func testALineThatDoesNotMatchJoinsTheOneBefore() {
        let parsed = TranscriptParser.parse(
            "[00:00:01] You: first line\ncontinues here\n\n[00:00:05] Speaker 1: second")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "first line continues here")
    }

    func testAFileWithNoTimestampsBecomesOneLinePerLineWithNoSpeaker() {
        let parsed = TranscriptParser.parse("hello there\nsecond line\r\nthird")
        XCTAssertEqual(parsed.map(\.text), ["hello there", "second line", "third"])
        XCTAssertTrue(parsed.allSatisfy { $0.speaker.isEmpty && $0.start == 0 })
    }

    func testEmptyInputGivesNoLinesAndTheClockIsFormatted() {
        XCTAssertTrue(TranscriptParser.parse("").isEmpty)
        XCTAssertTrue(TranscriptParser.parse("\n \n").isEmpty)
        XCTAssertEqual(TranscriptParser.clock(0), "00:00:00")
        XCTAssertEqual(TranscriptParser.clock(3661.9), "01:01:01")
        XCTAssertEqual(TranscriptParser.clock(-5), "00:00:00")
        XCTAssertEqual(TranscriptParser.parse("[100:00:00] You: long").first?.start, 360_000)
    }

    func testASpeakerLabelCanBeRenamedAndStillParses() {
        let renamed = SpeakerLabels.rename(
            "Speaker 1", to: "Dana", in: "[00:00:01] Speaker 1: Hi\n[00:00:02] You: Hello")
        let parsed = TranscriptParser.parse(renamed)
        XCTAssertEqual(parsed.map(\.speaker), ["Dana", "You"])
    }
}
