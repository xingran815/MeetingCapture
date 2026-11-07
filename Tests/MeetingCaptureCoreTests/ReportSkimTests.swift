import XCTest

@testable import MeetingCaptureCore

/// D-87: reports built to skim. Priority, the "At a glance" box and keyword highlights,
/// in HTML, markdown and the terminal. Everything runs in process, with invented data.
final class ReportSkimTests: XCTestCase {

    // MARK: Builders

    private func item(
        _ text: String, priority: String? = nil, keywords: [String]? = nil, speaker: String? = nil,
        owner: String? = nil, due: String? = nil, answer: String? = nil, confidence: String? = nil,
        reason: String? = nil
    ) -> Report.Item {
        var i = Report.Item(
            text: text, speaker: speaker, owner: owner, due: due, answer: answer, confidence: confidence,
            reason: reason)
        i.priority = priority
        i.keywords = keywords
        return i
    }

    private func report(_ sections: [Report.Section], notices: [String] = []) -> Report {
        Report(
            topic: "Skim test", scenario: "meeting", scenarioTitle: "Company meeting",
            createdAt: "2027-01-15T08:00:00Z",
            durationSeconds: 60, language: "en", models: .init(), reviewed: true, notices: notices, sections: sections,
            reviewChanges: [], transcript: [])
    }

    private func sec(_ id: String, _ items: [Report.Item]) -> Report.Section {
        Report.Section(id: id, title: id.capitalized, kind: .bullets, note: nil, items: items)
    }

    private func sec(_ id: String, _ kind: SectionKind, title: String? = nil, _ items: [Report.Item])
        -> Report.Section
    {
        Report.Section(id: id, title: title ?? id.capitalized, kind: kind, note: nil, items: items)
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    private func tagCounts(_ html: String, excluding: Set<String> = []) -> [String: Int] {
        let regex = try! NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9]*)")
        let ns = html as NSString
        var out: [String: Int] = [:]
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if !excluding.contains(name) { out[name, default: 0] += 1 }
        }
        return out
    }

    // MARK: highlight and wrap

    func testKeywordsMatchInAnyCaseAndKeepTheTextsOwnCase() {
        XCTAssertEqual(
            ReportRenderer.highlight("Deploy on FRIDAY, or friday", ["Friday"]),
            "Deploy on <mark>FRIDAY</mark>, or <mark>friday</mark>")
    }

    func testOverlappingKeywordsNeverNestOrBreakMarkup() {
        let out = ReportRenderer.highlight("alpha beta gamma", ["alpha beta", "beta gamma", "beta"])
        XCTAssertEqual(out, "<mark>alpha beta</mark> gamma")
        XCTAssertEqual(count("<mark>", in: out), count("</mark>", in: out))
        XCTAssertFalse(out.contains("<mark><mark>"))
        XCTAssertFalse(out.contains("<mark>alpha <mark>"))
    }

    func testTheLongestKeywordWinsAtTheSameStart() {
        XCTAssertEqual(ReportRenderer.highlight("abcd e", ["ab", "abcd", "abc"]), "<mark>abcd</mark> e")
        XCTAssertEqual(ReportRenderer.highlight("abcd e", ["abcd", "ab"]), "<mark>abcd</mark> e")
    }

    func testAKeywordInsideALaterOrEarlierKeywordDoesNotMarkTwice() {
        XCTAssertEqual(ReportRenderer.highlight("the big red dog", ["red", "big red"]), "the <mark>big red</mark> dog")
    }

    func testEveryRepeatedOccurrenceIsMarked() {
        let out = ReportRenderer.highlight("foo bar foo baz FOO", ["foo"])
        XCTAssertEqual(out, "<mark>foo</mark> bar <mark>foo</mark> baz <mark>FOO</mark>")
    }

    func testNoKeywordsMeansOnlyEscaping() {
        let text = "a <b> & \"q\" 'x'"
        let escaped = ReportRenderer.escape(text)
        XCTAssertEqual(ReportRenderer.highlight(text, nil), escaped)
        XCTAssertEqual(ReportRenderer.highlight(text, []), escaped)
        XCTAssertEqual(ReportRenderer.highlight(text, [""]), escaped)
        XCTAssertEqual(ReportRenderer.highlight(text, ["not there"]), escaped)
        XCTAssertEqual(ReportRenderer.highlight("", ["x"]), "")
    }

    func testAKeywordIsMatchedInTheRawTextNotInTheEscapedEntities() {
        XCTAssertEqual(ReportRenderer.highlight("a & b", ["amp"]), "a &amp; b", "amp is not in the raw text")
        XCTAssertEqual(ReportRenderer.highlight("a &lt; b", ["lt"]), "a &amp;<mark>lt</mark>; b")
        XCTAssertEqual(ReportRenderer.highlight("a & b", ["&"]), "a <mark>&amp;</mark> b")
        XCTAssertEqual(ReportRenderer.highlight("a <b> c", ["<b>"]), "a <mark>&lt;b&gt;</mark> c")
        XCTAssertEqual(ReportRenderer.highlight("say \"hi\"", ["\"hi\""]), "say <mark>&quot;hi&quot;</mark>")
    }

    func testWrapUsesTheGivenMarkersAndPieceFunction() {
        let out = ReportRenderer.wrap(
            "one two Three", ["two", "three"], open: "[", close: "]", piece: { $0.uppercased() })
        XCTAssertEqual(out, "ONE [TWO] [THREE]")
        XCTAssertEqual(ReportRenderer.wrap("same", nil, open: "[", close: "]", piece: { $0 }), "same")
    }

    func testKeywordsInTextWithEmojiAndCJKAreCutAtTheRightPlace() {
        XCTAssertEqual(ReportRenderer.highlight("🎉 季度计划 🎉 ok", ["季度计划"]), "🎉 <mark>季度计划</mark> 🎉 ok")
        XCTAssertEqual(ReportRenderer.highlight("🎉 party", ["🎉"]), "<mark>🎉</mark> party")
    }

    // MARK: XSS

    private let hostileKeywords = [
        "<script>", "</mark>", "\"", "&", "<img src=x onerror=alert(2)>", "onerror", "</script>", "<mark>", "'>",
    ]
    private let hostileText =
        "x<script>alert(1)</script>y </mark>&\"q\" <img src=x onerror=alert(2)> a<mark>b '>end"

    func testHostileKeywordsRenderInertAndAddNoTagsButTheRenderersMarks() {
        let plain = report([
            sec("a", [item(hostileText, priority: "high")]),
            sec("b", .qa, [item(hostileText, priority: "high", answer: hostileText)]),
            sec("c", .prose, [item(hostileText, priority: "high")]),
            sec("d", .actions, [item(hostileText, priority: "high", owner: hostileText, due: hostileText)]),
        ])
        var marked = plain
        for s in marked.sections.indices {
            for i in marked.sections[s].items.indices { marked.sections[s].items[i].keywords = hostileKeywords }
        }
        let withKeywords = ReportRenderer.html(marked)
        let without = ReportRenderer.html(plain)

        XSS.assertInert(withKeywords)
        XCTAssertEqual(
            count("<mark>", in: withKeywords), count("</mark>", in: withKeywords), "marks are balanced")
        XCTAssertGreaterThan(count("<mark>", in: withKeywords), 0)
        XCTAssertEqual(
            tagCounts(withKeywords, excluding: ["mark"]), tagCounts(without, excluding: ["mark"]),
            "keywords add no tag but mark")
        // Each mark holds only escaped text.
        let regex = try! NSRegularExpression(pattern: "<mark>(.*?)</mark>")
        let ns = withKeywords as NSString
        for m in regex.matches(in: withKeywords, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            XCTAssertFalse(inner.contains("<"), "markup inside a mark: \(inner)")
            XCTAssertFalse(inner.contains("\""), "a raw quote inside a mark: \(inner)")
        }
        XCTAssertFalse(withKeywords.contains("<script>alert"))
        XCTAssertFalse(withKeywords.contains("<img src=x"))
    }

    func testAKeywordBesideMarkupCharactersCannotCloseOrOpenATag() {
        for text in ["<b>word</b>", "word<", ">word", "\"word\"", "&word&", "'word'", "<<word>>", "</mark>word<mark>"] {
            let out = ReportRenderer.highlight(text, ["word"])
            XCTAssertTrue(out.contains("<mark>word</mark>"), text)
            let stripped = out.replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(
                of: "</mark>", with: "")
            XCTAssertEqual(stripped, ReportRenderer.escape(text), "same as plain escaping: \(text)")
        }
    }

    func testTheAtAGlanceBoxEscapesTheSectionTitleOwnerDueAndText() {
        let evil = "<script>alert(1)</script>"
        let r = report([
            sec(
                "s\"><script>x</script>", .actions, title: evil + "title",
                [
                    item(
                        evil + " do it", priority: "high", keywords: ["do it"], owner: "\"><img src=x onerror=1>",
                        due: "<b>soon</b>", confidence: "unsure")
                ])
        ])
        let html = ReportRenderer.html(r)
        XSS.assertInert(html)
        let start = try! XCTUnwrap(html.range(of: "<aside"))
        let end = try! XCTUnwrap(html.range(of: "</aside>"))
        let box = String(html[start.lowerBound..<end.upperBound])
        XCTAssertTrue(box.contains("&lt;script&gt;alert(1)&lt;/script&gt;title"))
        XCTAssertTrue(box.contains("Owner: &quot;&gt;&lt;img src=x onerror=1&gt;"))
        XCTAssertTrue(box.contains("Due: &lt;b&gt;soon&lt;/b&gt;"))
        XCTAssertTrue(box.contains("<mark>do it</mark>"))
        XCTAssertFalse(box.contains("<script"))
        XCTAssertFalse(box.contains("<img"))
        XCTAssertFalse(box.contains("<b>"))
        XCTAssertTrue(box.contains("href=\"#s-s&quot;&gt;&lt;script&gt;x&lt;/script&gt;\""))
    }

    // MARK: keywords(_:in:)

    func testKeywordsKeepOnlyPhrasesThatAreInTheItem() {
        let it = item("Ship the beta on Friday", answer: "Maybe Tuesday")
        let kept = SummaryPipeline.keywords(["beta", "Zebra", "Friday", "tuesday"], in: it)
        XCTAssertEqual(kept, ["beta", "Friday"], "the first two valid phrases are kept; Zebra is skipped")
        let skipped = SummaryPipeline.keywords(["Zebra", "Friday", "beta"], in: it)
        XCTAssertEqual(skipped, ["Friday", "beta"], "Zebra is not in the item, so it is skipped")
        XCTAssertNil(SummaryPipeline.keywords(["Zebra", "Unicorn"], in: it), "nothing found is nil, not []")
    }

    func testAKeywordOnlyInAnotherFieldIsDropped() {
        var it = item("Ship the beta")
        it.quote = "quoted words"
        it.detail = "detailed words"
        it.reason = "reasoned words"
        it.owner = "Owner Name"
        XCTAssertNil(SummaryPipeline.keywords(["quoted", "detailed", "reasoned", "Owner"], in: it))
    }

    func testKeywordsAreMatchedInAnyCaseAndKeepTheModelsSpelling() {
        let it = item("Ship the BETA")
        XCTAssertEqual(SummaryPipeline.keywords(["beta"], in: it), ["beta"])
    }

    func testTooShortAndTooLongKeywordsAreDropped() {
        let long60 = String(repeating: "a", count: 60)
        let long61 = String(repeating: "a", count: 61)
        let it = item("x \(long61) y b")
        XCTAssertNil(SummaryPipeline.keywords(["b", " b ", "", "   ", long61], in: it))
        let both = item("ok \(long60) and ab")
        XCTAssertEqual(
            SummaryPipeline.keywords([long61, "b", "", "ab", long60], in: both), ["ab", long60],
            "bad ones skipped first")
        XCTAssertEqual(
            SummaryPipeline.keywords([long61, "b", long60, "ab"], in: both), [long60, "ab"], "60 is allowed")
    }

    func testDuplicatesInAnyCaseAndWhitespaceAreCollapsed() {
        let it = item("Ship the beta on Friday")
        XCTAssertEqual(
            SummaryPipeline.keywords(["Beta", "beta", "BETA", " beta ", "friday"], in: it), ["Beta", "friday"])
        XCTAssertEqual(
            SummaryPipeline.keywords(["", "  ", "Beta", "beta"], in: it), ["Beta"],
            "blank first, then one real one; its repeat adds nothing")
    }

    func testNonStringKeywordsAreIgnored() {
        let it = item("Ship the beta on Friday 12")
        let raw: [Any] = [1, NSNull(), ["beta"], ["a": "b"], true, "beta", 12, "Friday"]
        XCTAssertEqual(SummaryPipeline.keywords(raw, in: it), ["beta", "Friday"])
        let rawFirst: [Any] = [1, NSNull(), ["beta"], true, 12, "Friday"]
        XCTAssertEqual(SummaryPipeline.keywords(rawFirst, in: it), ["Friday"], "non-strings skipped")
        XCTAssertNil(SummaryPipeline.keywords("beta", in: it), "a string instead of a list")
        XCTAssertNil(SummaryPipeline.keywords(nil, in: it))
        XCTAssertNil(SummaryPipeline.keywords([String: Any](), in: it))
        XCTAssertNil(SummaryPipeline.keywords([Any](), in: it))
    }

    func testAtMostTwoKeywordsAreKept() {
        let it = item("one two three four five")
        XCTAssertEqual(SummaryPipeline.keywords(["one", "two", "three", "four", "five"], in: it), ["one", "two"])
        XCTAssertEqual(SummaryPipeline.maxKeywords, 2)
        // A dropped phrase doesn't use up a place.
        XCTAssertEqual(SummaryPipeline.keywords(["zzz", "yyy", "two", "three", "four"], in: it), ["two", "three"])
    }

    func testKeywordsLookInTheTextAndTheAnswerOfTheItem() {
        let qa = item("What is the plan?", answer: "Launch in March")
        XCTAssertEqual(SummaryPipeline.keywords(["plan", "March"], in: qa), ["plan", "March"])
        XCTAssertEqual(
            SummaryPipeline.keywords(["Zebra", "March", "plan"], in: qa), ["March", "plan"],
            "a phrase only in the answer counts")
        let noText = Report.Item(answer: "only an answer here")
        XCTAssertEqual(SummaryPipeline.keywords(["answer"], in: noText), ["answer"])
        let empty = Report.Item()
        XCTAssertNil(SummaryPipeline.keywords(["anything"], in: empty))
    }

    // MARK: Priority and the box

    func testKeyItemsKeepSectionOrderAndStopAtEight() {
        let a = (1...4).map { item("a\($0)", priority: "high") }
        let b = (1...4).map { item("b\($0)", priority: "high") }
        let c = (1...4).map { item("c\($0)", priority: "high") }
        let r = report([sec("a", a), sec("b", b + [item("b-normal")]), sec("c", c)])
        let keys = ReportRenderer.keyItems(r)
        XCTAssertEqual(keys.map { $0.item.text }, ["a1", "a2", "a3", "a4", "b1", "b2", "b3", "b4"])
        XCTAssertEqual(keys.map { $0.section.id }, Array(repeating: "a", count: 4) + Array(repeating: "b", count: 4))
        XCTAssertEqual(ReportRenderer.keyItems(r, limit: 2).map { $0.item.text }, ["a1", "a2"])
        let html = ReportRenderer.html(r)
        XCTAssertEqual(
            count("<li><a class=\"from\"", in: html), 8, "the box lists 8, though 12 items are marked Key")
        XCTAssertEqual(count("<span class=\"pri\">Key</span>", in: html), 12, "every high item still has its badge")
    }

    func testThereIsNoBoxWhenNothingIsHigh() {
        let r = report([
            sec("a", [item("low one", priority: "low"), item("normal"), item("no priority", priority: nil)])
        ])
        XCTAssertTrue(ReportRenderer.keyItems(r).isEmpty)
        let html = ReportRenderer.html(r)
        XCTAssertFalse(html.contains("<aside"))
        XCTAssertFalse(html.contains("At a glance"))
        XCTAssertFalse(html.contains("class=\"pri\""))
        XCTAssertFalse(ReportRenderer.markdown(r).contains("At a glance"))
        XCTAssertFalse(ReportRenderer.markdown(r).contains("Key:"))
        XCTAssertFalse(ReportRenderer.terminalSummary(r, ansi: false).contains("AT A GLANCE"))
        XCTAssertFalse(ReportRenderer.terminalSummary(r, ansi: false).contains("KEY"))
    }

    func testHighAndLowClassesAndTheKeyBadgeAppearOnlyOnThoseItems() {
        let r = report([
            sec(
                "a",
                [
                    item("is high", priority: "high"), item("is low", priority: "low"),
                    item("is normal", priority: "normal"), item("is unset"), item("is odd", priority: "HIGH"),
                ])
        ])
        let html = ReportRenderer.html(r)
        XCTAssertTrue(html.contains("<li class=\"high\"><span class=\"pri\">Key</span> is high</li>"))
        XCTAssertTrue(html.contains("<li class=\"low\">is low</li>"))
        XCTAssertTrue(html.contains("<li>is normal</li>"))
        XCTAssertTrue(html.contains("<li>is unset</li>"))
        XCTAssertTrue(html.contains("<li>is odd</li>"), "only the exact value high counts at render time")
        XCTAssertEqual(count("class=\"pri\"", in: html), 1)
        XCTAssertEqual(ReportRenderer.keyItems(r).count, 1)
    }

    func testEverySectionKindShowsTheKeyBadgeAndHighClassOnAHighItem() {
        let sections = SectionKind.allCases.enumerated().map { i, kind in
            sec("k\(i)", kind, [item("normal \(i)"), item("important \(i)", priority: "high", answer: "yes")])
        }
        let html = ReportRenderer.html(report(sections))
        XCTAssertEqual(count("<span class=\"pri\">Key</span>", in: html), SectionKind.allCases.count)
        let regex = try! NSRegularExpression(pattern: "class=\"[^\"]*\\bhigh\\b[^\"]*\"")
        XCTAssertEqual(
            regex.numberOfMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
            SectionKind.allCases.count)
    }

    func testEverySectionKindMarksALowItemWithTheLowClass() {
        // Found by this test: the qa and concepts markup leaves `low` out.
        for kind in SectionKind.allCases {
            let html = ReportRenderer.html(
                report([sec("k", kind, [item("background note", priority: "low", answer: "yes")])]))
            let regex = try! NSRegularExpression(pattern: "class=\"[^\"]*\\blow\\b[^\"]*\"")
            let n = regex.numberOfMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
            XCTAssertEqual(n, 1, "\(kind) shows a low item with class low")
        }
    }

    func testTheBoxCarriesOwnerDueAndUnsureFromTheItem() {
        let r = report([
            sec(
                "a", .actions,
                [item("Send it", priority: "high", owner: "Ana", due: "Friday", confidence: "unsure", reason: "r")])
        ])
        let html = ReportRenderer.html(r)
        let box = String(html[html.range(of: "<aside")!.lowerBound..<html.range(of: "</aside>")!.upperBound])
        XCTAssertTrue(box.contains("Owner: Ana"))
        XCTAssertTrue(box.contains("Due: Friday"))
        XCTAssertTrue(box.contains("Unsure"))
        XCTAssertTrue(box.contains("href=\"#s-a\""))
    }

    // MARK: Pipeline: what the replies become

    private func run(sections: String, review: String, redaction: Bool = false, transcript: String? = nil)
        async throws -> (SummaryOutcome, ScriptedBackend)
    {
        let backend = ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("meeting")
                case .normal: return sections
                case .frontier: return review
                }
            })
        let outcome = try await ReportFixtures.pipeline(backend, redaction: redaction).run(
            transcript: transcript ?? "[00:00:05] You: Hello there.\n[00:00:09] Speaker 1: Hi, let's begin.",
            forcedScenario: nil)
        return (outcome, backend)
    }

    private func rawItem(
        _ text: String, priority: Any? = nil, keywords: Any? = nil, answer: String = ""
    ) -> [String: Any] {
        var d: [String: Any] = [
            "text": text, "speaker": "", "owner": "", "due": "", "answer": answer, "quote": "", "detail": "",
            "confidence": "sure", "reason": "", "source": "transcript",
        ]
        if let priority { d["priority"] = priority }
        if let keywords { d["keywords"] = keywords }
        return d
    }

    private func reply(_ sections: [String: [[String: Any]]], review: Bool = false) -> String {
        var o: [String: Any] = ["topic": "T", "sections": sections]
        if review {
            o["changes"] = [[String: String]]()
            o["transcriptSuggestions"] = [[String: Any]]()
        }
        return Replies.json(o)
    }

    func testAnUnknownPriorityIsIgnoredAndTheKnownOnesKept() async throws {
        let list: [[String: Any]] = [
            rawItem("one", priority: "urgent"), rawItem("two", priority: "high"), rawItem("three", priority: " high"),
            rawItem("four", priority: 5), rawItem("five"), rawItem("six", priority: "low"),
            rawItem("seven", priority: "normal"), rawItem("eight", priority: "HIGH"), rawItem("nine", priority: ""),
        ]
        let (outcome, _) = try await run(
            sections: reply(["actions": list]), review: reply(["actions": list], review: true))
        let got = items(outcome.report, "actions").map(\.priority)
        XCTAssertEqual(got, [nil, "high", nil, nil, nil, "low", "normal", "high", nil])
    }

    func testReplyKeywordsAreFilteredAgainstEachItemsOwnText() async throws {
        let list: [[String: Any]] = [
            rawItem(
                "Ship the beta on Friday", priority: "high",
                keywords: ["Zebra", String(repeating: "b", count: 61), 3, "", "Friday", "beta", "ship"]),
            rawItem("No keywords here", keywords: "not a list"),
            rawItem("Question text", keywords: ["answer word"], answer: "an answer word appears"),
        ]
        let (outcome, _) = try await run(
            sections: reply(["who_said_what": list]), review: reply(["who_said_what": list], review: true))
        let got = items(outcome.report, "who_said_what")
        XCTAssertEqual(got[0].keywords, ["Friday", "beta"], "invalid phrases first are skipped; two are kept")
        XCTAssertNil(got[1].keywords)
        XCTAssertEqual(got[2].keywords, ["answer word"])
    }

    func testTheReviewIsGivenEachItemsPriorityAndKeywords() async throws {
        let draft: [[String: Any]] = [
            rawItem("Ship the beta on Friday", priority: "high", keywords: ["Zebra", "Friday", "beta"]),
            rawItem("Plain item"),
        ]
        let (_, backend) = try await run(
            sections: reply(["who_said_what": draft]), review: reply(["who_said_what": draft], review: true))
        let input = try XCTUnwrap(backend.calls(.frontier).first).input
        XCTAssertTrue(input.contains("\"priority\":\"high\""), input)
        XCTAssertTrue(input.contains("\"keywords\":[\"Friday\",\"beta\"]"), input)
        XCTAssertTrue(input.contains("\"priority\":\"normal\""), "an unset priority goes out as normal")
        XCTAssertTrue(input.contains("\"keywords\":[]"), "no keywords go out as an empty list")
    }

    func testBothItemSchemasRequirePriorityAndKeywords() async throws {
        let list: [[String: Any]] = [rawItem("Ship it", priority: "high", keywords: ["Ship"])]
        let (_, backend) = try await run(
            sections: reply(["actions": list]), review: reply(["actions": list], review: true))
        for tier in [ModelTier.normal, .frontier] {
            let schema = try XCTUnwrap(backend.calls(tier).first).schema
            try assertItemSchema(schema, "\(tier)")
        }
    }

    func testHighlightsShouldGiveWhoWhenWhatHowWhyButStayBalancedAndNotRepeat() throws {
        let template = try XCTUnwrap(ScenarioCatalog.builtIn.template(named: "meeting"))
        let prompt = SummaryPipeline.sectionsPrompt(template, language: "English")
        let line = try XCTUnwrap(
            prompt.split(separator: "\n").first { $0.contains("\"keywords\"") }.map(String.init), prompt)
        XCTAssertTrue(line.contains("one or two short phrases"), line)
        for word in ["who", "when", "what was decided", "how", "why"] { XCTAssertTrue(line.contains(word), word) }
        XCTAssertTrue(line.contains("About half the items get some"), line)
        XCTAssertTrue(line.contains("never highlight general words"), line)
        XCTAssertTrue(line.contains("never a fact already highlighted in another item"), line)
        XCTAssertTrue(line.contains("Only \"prose\" and \"bullets\" sections get keywords"), line)
        XCTAssertTrue(line.contains("every other kind gets an empty list"), line)
        XCTAssertFalse(line.contains("At most one item in three"), line)
        XCTAssertEqual(SummaryPipeline.maxKeywords, 2)
    }

    // MARK: withoutRepeatedHighlights

    private func keywordsAfterDedupe(_ lists: [[String]?]) -> [[String]?] {
        let r = report(lists.enumerated().map { i, k in sec("s\(i)", [item("item \(i)", keywords: k)]) })
        return SummaryPipeline.withoutRepeatedHighlights(r).sections.map { $0.items[0].keywords }
    }

    func testARepeatedHighlightInALaterSectionIsDropped() {
        XCTAssertEqual(keywordsAfterDedupe([["Friday"], ["Friday", "Ana"]]).map { $0 ?? [] }, [["Friday"], ["Ana"]])
    }

    func testRepeatsAreFoundInAnyCase() {
        XCTAssertEqual(
            keywordsAfterDedupe([["Friday"], ["FRIDAY"], ["friday"]]).map { $0 ?? [] }, [["Friday"], [], []])
    }

    func testAContainedOrContainingPhraseCountsAsARepeat() {
        XCTAssertEqual(
            keywordsAfterDedupe([["target the 17th"], ["the 17th"]]).map { $0 ?? [] }, [["target the 17th"], []])
        XCTAssertEqual(keywordsAfterDedupe([["the 17th"], ["target the 17th"]]).map { $0 ?? [] }, [["the 17th"], []])
    }

    func testTheFirstOccurrenceIsKeptAndDistinctPhrasesSurvive() {
        let out = keywordsAfterDedupe([["Ana", "Friday"], ["Postgres", "Ana"], ["budget"]])
        XCTAssertEqual(out.map { $0 ?? [] }, [["Ana", "Friday"], ["Postgres"], ["budget"]])
    }

    func testRepeatsInsideOneSectionAreDroppedByItemOrder() {
        let r = report([
            sec("a", [item("one", keywords: ["Friday"]), item("two", keywords: ["Friday", "Ana"]), item("three")])
        ])
        let out = SummaryPipeline.withoutRepeatedHighlights(r).sections[0].items
        XCTAssertEqual(out.map(\.keywords), [["Friday"], ["Ana"], nil])
    }

    func testAnItemLeftWithNoHighlightGetsNilNotAnEmptyList() {
        let out = keywordsAfterDedupe([["Friday"], ["friday"]])
        XCTAssertNil(out[1])
        XCTAssertNotNil(out[0])
    }

    func testARepeatedHighlightGetsOneMarkInTheRenderedSections() async throws {
        let prose: [[String: Any]] = [rawItem("We target the 17th for launch", keywords: ["target the 17th"])]
        let bullets: [[String: Any]] = [
            rawItem("Launch moves to the 17th", keywords: ["the 17th"]),
            rawItem("Ana owns QA", keywords: ["Ana"]),
        ]
        let both = ["summary": prose, "who_said_what": bullets]
        let (outcome, _) = try await run(sections: reply(both), review: reply(both, review: true))
        let got = items(outcome.report, "who_said_what")
        XCTAssertNil(got[0].keywords)
        XCTAssertEqual(got[1].keywords, ["Ana"])
        let html = ReportRenderer.html(outcome.report)
        XCTAssertEqual(count("<mark>target the 17th</mark>", in: html), 1)
        XCTAssertEqual(count("the 17th</mark>", in: html), 1, "the repeat has no mark")
        XCTAssertEqual(count("<mark>Ana</mark>", in: html), 1)
    }

    func testNotEverySectionNeedsHighlightsOnlyProseAndBulletsKeepKeywords() async throws {
        let specs = SectionKind.allCases.map {
            """
            {"id":"s_\($0.rawValue)","title":"Sec \($0.rawValue)","kind":"\($0.rawValue)","instructions":"x"}
            """
        }.joined(separator: ",")
        let json = """
            {"name":"meeting","title":"Every kind","description":"d","rules":[],"sections":[\(specs)]}
            """
        let template = try JSONDecoder().decode(ScenarioTemplate.self, from: Data(json.utf8))
        let catalog = ScenarioCatalog(templates: [template])
        var raw: [String: [[String: Any]]] = [:]
        for kind in SectionKind.allCases {
            raw["s_\(kind.rawValue)"] = [
                rawItem("Marker_\(kind.rawValue) text", keywords: ["Marker_\(kind.rawValue)"])
            ]
        }
        let backend = ScriptedBackend(
            onComplete: { call in
                switch call.tier {
                case .cheap: return Replies.classify("meeting")
                case .normal: return self.reply(raw)
                case .frontier: return self.reply(raw, review: true)
                }
            })
        let outcome = try await ReportFixtures.pipeline(backend, redaction: false, catalog: catalog).run(
            transcript: "[00:00:05] You: Hello there.\n[00:00:09] Speaker 1: Hi, let's begin.", forcedScenario: nil)
        let html = ReportRenderer.html(outcome.report)
        for kind in SectionKind.allCases {
            let id = "s_\(kind.rawValue)"
            let got = items(outcome.report, id).first?.keywords
            let start = try XCTUnwrap(html.range(of: "id=\"s-\(id)\""), id)
            let rest = html[start.upperBound...]
            let end = rest.range(of: "</section>")?.lowerBound ?? rest.endIndex
            let marked = rest[..<end].contains("<mark>Marker_\(kind.rawValue)</mark>")
            if kind == .prose || kind == .bullets {
                XCTAssertEqual(got, ["Marker_\(kind.rawValue)"], "\(kind) keeps its keyword")
                XCTAssertTrue(marked, "\(kind) is highlighted")
            } else {
                XCTAssertNil(got, "\(kind) gets no keywords")
                XCTAssertFalse(marked, "\(kind) has no <mark>")
            }
        }
    }

    func testActionsAndToDosNeedNoHighlights() async throws {
        let actions: [[String: Any]] = [rawItem("Send the report on Friday", priority: "high", keywords: ["Friday"])]
        let bullets: [[String: Any]] = [rawItem("We chose Postgres for storage", keywords: ["Postgres"])]
        let both = ["actions": actions, "who_said_what": bullets]
        let (outcome, _) = try await run(sections: reply(both), review: reply(both, review: true))
        XCTAssertNil(items(outcome.report, "actions").first?.keywords)
        XCTAssertEqual(items(outcome.report, "who_said_what").first?.keywords, ["Postgres"])
        let html = ReportRenderer.html(outcome.report)
        XCTAssertTrue(html.contains("<mark>Postgres</mark>"))
        XCTAssertFalse(html.contains("<mark>Friday</mark>"))
    }

    // MARK: Tokens

    func testAKeywordThatWasATokenComesBackRestoredAndStillHighlights() async throws {
        let transcript = "[00:00:01] You: Mail priya@example.com now."
        let list: [[String: Any]] = [
            rawItem("Send the file to <EMAIL_1> today", priority: "high", keywords: ["<EMAIL_1>"])
        ]
        let (outcome, backend) = try await run(
            sections: reply(["who_said_what": list]), review: reply(["who_said_what": list], review: true),
            redaction: true,
            transcript: transcript)
        let email = "priya@example.com"
        let it = try XCTUnwrap(items(outcome.report, "who_said_what").first)
        XCTAssertEqual(it.keywords, [email])
        XCTAssertEqual(it.text, "Send the file to \(email) today")
        XCTAssertEqual(outcome.flaggedTokens, [])
        let input = try XCTUnwrap(backend.calls(.frontier).first).input
        XCTAssertFalse(input.contains(email), "the reviewer still sees the token only")
        XCTAssertTrue(input.contains("<EMAIL_1>"))

        let html = ReportRenderer.html(outcome.report)
        XCTAssertTrue(html.contains("<mark>\(email)</mark>"), "the restored address is highlighted")
        XCTAssertFalse(html.contains("EMAIL_1"))
        XCTAssertTrue(ReportRenderer.markdown(outcome.report).contains("**\(email)**"))
        XCTAssertTrue(
            ReportRenderer.terminalSummary(outcome.report, ansi: true).contains("\u{1B}[33m\(email)\u{1B}[39m"))
    }

    func testAKeywordWithATokenInsideALongerPhraseIsRestoredToo() async throws {
        let transcript = "[00:00:01] You: Mail priya@example.com now."
        let list: [[String: Any]] = [rawItem("Mail <EMAIL_1> now", keywords: ["Mail <EMAIL_1>"])]
        let (outcome, _) = try await run(
            sections: reply(["who_said_what": list]), review: reply(["who_said_what": list], review: true),
            redaction: true,
            transcript: transcript)
        XCTAssertEqual(items(outcome.report, "who_said_what").first?.keywords, ["Mail priya@example.com"])
    }

    // MARK: Markdown

    func testMarkdownPrefixesKeyAndBoldsKeywords() {
        let r = report([
            sec(
                "a",
                [
                    item("Ship by FRIDAY and test", priority: "high", keywords: ["friday", "test"]),
                    item("Background note", priority: "low", keywords: ["note"]),
                    item("Nothing special"),
                ]),
            sec("p", .prose, [item("Prose with a deadline today", priority: "high", keywords: ["deadline"])]),
            sec(
                "t", .actions,
                [item("Pay the invoice", priority: "high", keywords: ["invoice"], owner: "Ana", due: "Friday")]),
        ])
        let md = ReportRenderer.markdown(r)
        XCTAssertTrue(md.contains("- **Key:** Ship by **FRIDAY** and **test**"), md)
        XCTAssertTrue(md.contains("- Background **note**"))
        XCTAssertTrue(md.contains("- Nothing special\n"))
        XCTAssertEqual(count("**Key:**", in: md), 3, "one per Key item in the sections; the box has none")
        XCTAssertTrue(md.contains("**Key:** Prose with a **deadline** today"))
        XCTAssertTrue(md.contains("- [ ] **Key:** Pay the **invoice** (owner: Ana) (due: Friday)"))
        let glance = try! XCTUnwrap(md.range(of: "## At a glance"))
        let first = try! XCTUnwrap(md.range(of: "\n## A\n"))
        XCTAssertLessThan(glance.lowerBound, first.lowerBound, "the box comes before the sections")
        XCTAssertTrue(md.contains("- Ship by **FRIDAY** and **test** _(A)_"))
    }

    func testMarkdownKeepsBoldBalancedForAQuestionWithKeywords() {
        // Found by this test: a qa line is wrapped in ** itself, so a Key prefix or a keyword nests inside it.
        let r = report([
            sec(
                "q", .qa,
                [item("Does the cutover clash?", priority: "high", keywords: ["cutover"], answer: "Not sure yet")])
        ])
        let md = ReportRenderer.markdown(r)
        let line = try! XCTUnwrap(
            md.components(separatedBy: "\n").last { $0.hasPrefix("- **") && $0.contains("cutover") })
        let inner = line.dropFirst(4).dropLast(2)
        XCTAssertFalse(inner.contains("**"), "bold inside bold breaks the line: \(line)")
    }

    // MARK: Terminal

    private let esc = "\u{1B}"

    private func hostileTerminalReport() -> Report {
        let bad = "\(esc)[2J\(esc)]0;owned\u{07}\u{8}\u{9B}31m\r\u{7F}"
        let text = "Deploy \(esc)[31mred\(esc)[0m by Friday\(bad) ok"
        let kw = ["\(esc)[31mred", "Friday", "\(esc)[1mfake", "\u{07}"]
        let it = item(
            text, priority: "high", keywords: kw, speaker: "sp\(bad)", owner: "o\(bad)", due: "d\(bad)",
            answer: "answer \(esc)[31mred \(bad)", confidence: "unsure", reason: "r\(bad)")
        return report(
            [
                sec("a\(bad)", .bullets, title: "Sec\(bad)", [it]), sec("q", .qa, title: "Q\(bad)", [it]),
                sec("t", .actions, [it]),
            ], notices: ["note\(bad)"])
    }

    func testTheTerminalSummaryHasNoEscapeCharacterAtAllWhenAnsiIsOff() {
        let out = ReportRenderer.terminalSummary(hostileTerminalReport(), ansi: false)
        XCTAssertFalse(out.unicodeScalars.contains("\u{1B}"))
        let bad = out.unicodeScalars.filter { $0 != "\n" && CharacterSet.controlCharacters.contains($0) }
        XCTAssertTrue(bad.isEmpty, "\(bad.map { String($0.value, radix: 16) })")
        XCTAssertTrue(out.contains("AT A GLANCE"))
        XCTAssertTrue(out.contains("by Friday"), "keywords are plain text")
    }

    func testWithAnsiOnTheOnlyEscapesAreBalancedHighlightOnAndOff() {
        let out = ReportRenderer.terminalSummary(hostileTerminalReport(), ansi: true)
        let on = "\(esc)[33m"
        let off = "\(esc)[39m"
        // Walk the output: every ESC must start one of the two sequences, and they must alternate.
        var rest = Substring(out)
        var depth = 0
        var opens = 0
        while let i = rest.firstIndex(of: Character(esc)) {
            rest = rest[i...]
            if rest.hasPrefix(on) {
                depth += 1
                opens += 1
                rest = rest.dropFirst(on.count)
            } else if rest.hasPrefix(off) {
                depth -= 1
                rest = rest.dropFirst(off.count)
            } else {
                return XCTFail("an escape sequence that is not a highlight: \(rest.prefix(8).debugDescription)")
            }
            XCTAssertTrue((0...1).contains(depth), "highlight must not nest or close twice")
        }
        XCTAssertEqual(depth, 0, "every highlight is closed")
        XCTAssertGreaterThan(opens, 0)

        let stripped = out.replacingOccurrences(of: on, with: "").replacingOccurrences(of: off, with: "")
        let bad = stripped.unicodeScalars.filter { $0 != "\n" && CharacterSet.controlCharacters.contains($0) }
        XCTAssertTrue(bad.isEmpty, "control characters from model text: \(bad.map { String($0.value, radix: 16) })")
        XCTAssertTrue(out.contains("\(on)Friday\(off)"))
        XCTAssertTrue(
            out.contains("\(on)[31mred\(off)"), "the control byte inside a keyword is stripped, the text kept")
    }

    func testWithAnsiOffAndOnTheTextIsTheSameOnceTheHighlightIsTaken_Out() {
        let r = hostileTerminalReport()
        let on = ReportRenderer.terminalSummary(r, ansi: true)
            .replacingOccurrences(of: "\(esc)[33m", with: "").replacingOccurrences(of: "\(esc)[39m", with: "")
        XCTAssertEqual(on, ReportRenderer.terminalSummary(r, ansi: false))
    }

    func testHighlightIsColorNotBoldInTheHtmlCss() throws {
        // The user asked for a color highlight, not bold: the mark rule must not set font-weight.
        let html = ReportRenderer.html(report([sec("a", .bullets, [item("Deploy Friday", keywords: ["Friday"])])]))
        // The bare element rule, not the unrelated `.mark{` badge class.
        let start = try XCTUnwrap(
            html.range(of: #"(?<![.\w-])mark\{"#, options: .regularExpression), "the HTML has a mark rule")
        let end = try XCTUnwrap(html[start.upperBound...].firstIndex(of: "}"))
        let rule = String(html[start.lowerBound..<end])
        XCTAssertFalse(rule.contains("font-weight"), rule)
        XCTAssertTrue(rule.contains("background") || rule.contains("color"), rule)
    }

    func testTerminalKeywordsAreYellowAndNeverBold() {
        let out = ReportRenderer.terminalSummary(
            report([sec("a", .bullets, [item("Deploy Friday", priority: "high", keywords: ["Friday"])])]), ansi: true)
        XCTAssertTrue(out.contains("\(esc)[33mFriday\(esc)[39m"))
        XCTAssertFalse(out.contains("\(esc)[1m"), "no bold escape")
        XCTAssertFalse(out.contains("\(esc)[22m"), "no bold-off escape")
    }
}

/// Checks that a JSON Schema string has an item object that requires `priority` and `keywords`.
func assertItemSchema(_ schema: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let root = try JSONSerialization.jsonObject(with: Data(schema.utf8))
    var found: [[String: Any]] = []
    func walk(_ node: Any) {
        if let d = node as? [String: Any] {
            if let props = d["properties"] as? [String: Any], props["priority"] != nil { found.append(d) }
            for v in d.values { walk(v) }
        } else if let a = node as? [Any] {
            a.forEach(walk)
        }
    }
    walk(root)
    XCTAssertFalse(found.isEmpty, "\(label): no item schema with priority", file: file, line: line)
    for d in found {
        let required = d["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("priority"), "\(label): priority required", file: file, line: line)
        XCTAssertTrue(required.contains("keywords"), "\(label): keywords required", file: file, line: line)
        XCTAssertEqual(d["additionalProperties"] as? Bool, false, file: file, line: line)
        let props = d["properties"] as? [String: Any] ?? [:]
        let priority = props["priority"] as? [String: Any]
        XCTAssertEqual(priority?["enum"] as? [String], ["high", "normal", "low"], file: file, line: line)
        let keywords = props["keywords"] as? [String: Any]
        XCTAssertEqual(keywords?["type"] as? String, "array", file: file, line: line)
        XCTAssertEqual((keywords?["items"] as? [String: Any])?["type"] as? String, "string", file: file, line: line)
    }
}

/// The schemas and the review input as the fake `claude` really receives them.
final class ReportSkimCLITests: GuardedTestCase {

    private var world: FakeCLIWorld!

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    func testTheSchemaArgumentsOfTheSectionsAndReviewCallsRequirePriorityAndKeywords() async throws {
        try world.installFixture("meeting")
        let p = ReportFixtures.pipeline(CLISummaryBackend(router: world.router()))
        _ = try await p.run(transcript: try ReportFixtures.read("meeting", "transcript.txt"))
        let calls = world.calls(.claude)
        XCTAssertEqual(calls.count, 3, "classify, sections, review")
        for (n, label) in [(1, "sections"), (2, "review")] {
            let args = calls[n].args
            let i = try XCTUnwrap(args.firstIndex(of: "--json-schema"), "\(label) sends a schema")
            try assertItemSchema(args[i + 1], label)
        }
        let review = calls[2].stdin
        XCTAssertTrue(review.contains("\"priority\":\"high\""), "the review input carries the draft's priority")
        XCTAssertTrue(review.contains("\"keywords\":["), "and its keywords")
        XCTAssertTrue(review.contains("\"keywords\":[\"migration\"]"))
    }
}
