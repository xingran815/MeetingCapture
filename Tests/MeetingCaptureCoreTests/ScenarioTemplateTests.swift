import XCTest

@testable import MeetingCaptureCore

/// Scenario templates are data (spec 04): the six built-ins, and user files that add or replace one.
final class ScenarioTemplateTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func spec(_ id: String, kind: SectionKind = .bullets, title: String? = nil) -> ScenarioTemplate.SectionSpec
    {
        .init(id: id, title: title ?? id.capitalized, kind: kind, instructions: "Fill \(id).", note: nil)
    }

    private func template(
        name: String = "standup", title: String = "Stand-up", sections: [ScenarioTemplate.SectionSpec]? = nil
    ) -> ScenarioTemplate {
        .init(
            name: name, title: title, description: "A daily stand-up.", rules: ["Be brief."],
            sections: sections ?? [spec("summary", kind: .prose), spec("blockers")])
    }

    private func json(_ t: ScenarioTemplate) throws -> String {
        String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
    }

    // MARK: Built-ins

    func testEveryBuiltInTemplatePassesItsOwnCheck() {
        for t in ScenarioCatalog.builtInTemplates { XCTAssertNil(t.problem(), "\(t.name): \(t.problem() ?? "")") }
    }

    func testTheSixScenariosOfTheSpecAreThere() {
        XCTAssertEqual(ScenarioCatalog.builtIn.names, ReportFixtures.scenarios)
        XCTAssertEqual(ScenarioCatalog.fallbackName, "general")
        XCTAssertEqual(ScenarioCatalog.builtIn.general.name, "general")
        XCTAssertNil(ScenarioCatalog.builtIn.template(named: "podcast"))
        XCTAssertEqual(ScenarioCatalog.builtIn.template(named: "THERAPY")?.name, "therapy")
    }

    func testTheSectionsMatchTheSpecTable() {
        let titles = { (name: String) in ScenarioCatalog.builtIn.template(named: name)!.sections.map(\.title) }
        XCTAssertEqual(titles("meeting").count, 5)
        XCTAssertEqual(titles("therapy").count, 7)
        XCTAssertEqual(titles("interview").count, 6)
        XCTAssertEqual(titles("one_on_one").count, 6)
        XCTAssertEqual(titles("lecture").count, 5)
        XCTAssertEqual(titles("general").count, 5)
        for name in ReportFixtures.scenarios {
            let t = ScenarioCatalog.builtIn.template(named: name)!
            XCTAssertEqual(t.sections.first?.id, "summary", "\(name) starts with a summary")
            XCTAssertEqual(t.sections.last?.id, "insights", "\(name) ends with the AI insights")
            XCTAssertEqual(t.sections.last?.kind, .insights)
            XCTAssertNotNil(t.sections.last?.note, "\(name): the insights are labelled as the AI's")
            XCTAssertFalse(t.description.isEmpty)
        }
        XCTAssertTrue(titles("meeting").contains("Actions and to-dos"))
        XCTAssertTrue(titles("therapy").contains("SMART goals"))
    }

    func testOnlyTherapyAndLectureSearchForConcepts() {
        let withConcepts = ScenarioCatalog.builtIn.templates.filter { $0.conceptSection != nil }.map(\.name)
        XCTAssertEqual(Set(withConcepts), ["therapy", "lecture"])
    }

    func testTheTherapyRulesAreInTheTemplate() throws {
        let therapy = try XCTUnwrap(ScenarioCatalog.builtIn.template(named: "therapy"))
        let rules = therapy.rules.joined(separator: " ")
        for phrase in ["Do not diagnose", "Do not give medical advice", "Do not take sides", "warm"] {
            XCTAssertTrue(rules.contains(phrase), phrase)
        }
        XCTAssertTrue(rules.contains("therapist's own words"))
    }

    // MARK: problem()

    func testWhatMakesATemplateUnusable() {
        XCTAssertNil(template().problem())
        XCTAssertNotNil(template(name: "Stand-up").problem(), "uppercase and a dash")
        XCTAssertNotNil(template(name: "../x").problem())
        XCTAssertNotNil(template(name: "").problem())
        XCTAssertNotNil(template(name: "1abc").problem(), "starts with a letter")
        XCTAssertNotNil(template(name: String(repeating: "a", count: 40)).problem())
        XCTAssertNotNil(template(title: "").problem())
        XCTAssertNotNil(template(title: String(repeating: "t", count: 61)).problem())
        XCTAssertNotNil(template(sections: []).problem())
        XCTAssertNotNil(template(sections: (0..<13).map { spec("s\($0)") }).problem())
        XCTAssertNil(template(sections: (0..<12).map { spec("s\($0)") }).problem())
        XCTAssertNotNil(template(sections: [spec("a"), spec("a")]).problem())
        XCTAssertNotNil(template(sections: [spec("A b")]).problem())
        XCTAssertNotNil(template(sections: [spec("a", title: "")]).problem())
        XCTAssertNotNil(template(sections: [spec("a", title: String(repeating: "t", count: 81))]).problem())
        XCTAssertNotNil(template(sections: [spec("a", kind: .concepts), spec("b", kind: .concepts)]).problem())
        XCTAssertNil(template(sections: [spec("a", kind: .concepts), spec("b")]).problem())
    }

    // MARK: User templates

    func testAUserFileAddsAScenarioAndAnotherReplacesABuiltInOne() throws {
        try write("standup.json", try json(template()))
        try write("general.json", try json(template(name: "general", title: "My general")))
        try write("notes.txt", "not a template")
        let loaded = ScenarioCatalog.load(userDirectory: dir)
        XCTAssertEqual(loaded.warnings, [])
        XCTAssertEqual(Set(loaded.catalog.names), Set(ReportFixtures.scenarios + ["standup"]))
        XCTAssertEqual(loaded.catalog.names.count, 7, "the replaced one is not listed twice")
        XCTAssertEqual(loaded.catalog.template(named: "standup")?.title, "Stand-up")
        XCTAssertEqual(loaded.catalog.template(named: "general")?.title, "My general")
        XCTAssertEqual(loaded.catalog.general.title, "My general", "the fallback is the replaced one")
        XCTAssertEqual(loaded.catalog.template(named: "meeting")?.title, "Company meeting", "the others are untouched")
    }

    func testInvalidFilesAreSkippedWithAWarningNamingTheFile() throws {
        try write("broken.json", "{not json")
        try write("dupid.json", try json(template(name: "dupid", sections: [spec("a"), spec("a")])))
        try write("badname.json", try json(template(name: "Bad Name")))
        try write(
            "badkind.json",
            #"{"name":"badkind","title":"T","description":"d","rules":[],"sections":[{"id":"a","title":"A","kind":"html","instructions":"x"}]}"#
        )
        try write("missing.json", #"{"name":"missing","title":"T"}"#)
        try write("big.json", String(repeating: " ", count: 250_000))
        try write("good.json", try json(template(name: "good")))
        let loaded = ScenarioCatalog.load(userDirectory: dir)
        XCTAssertEqual(loaded.warnings.count, 6, "\(loaded.warnings)")
        for file in ["broken.json", "dupid.json", "badname.json", "badkind.json", "missing.json", "big.json"] {
            XCTAssertTrue(loaded.warnings.contains { $0.contains(file) }, file)
        }
        XCTAssertTrue(loaded.warnings.contains { $0.contains("two sections share an id") })
        XCTAssertNotNil(loaded.catalog.template(named: "good"), "a good file next to bad ones still loads")
        XCTAssertNil(loaded.catalog.template(named: "dupid"))
        XCTAssertEqual(loaded.catalog.names.count, 7)
    }

    func testAFolderThatDoesNotExistGivesTheBuiltInsAndNoWarning() {
        let loaded = ScenarioCatalog.load(userDirectory: dir.appendingPathComponent("nope"))
        XCTAssertEqual(loaded.catalog.names, ReportFixtures.scenarios)
        XCTAssertEqual(loaded.warnings, [])
        XCTAssertEqual(ScenarioCatalog.load(userDirectory: nil).catalog.names, ReportFixtures.scenarios)
    }

    func testAUserTemplateReachesTheClassifierAndTheSectionsPrompt() async throws {
        try write("standup.json", try json(template()))
        let catalog = ScenarioCatalog.load(userDirectory: dir).catalog
        let backend = ScriptedBackend(onComplete: { call in
            switch call.tier {
            case .cheap: return Replies.classify("standup")
            case .normal: return Replies.sections(["summary": ["s"], "blockers": ["none"]])
            case .frontier: return Replies.review(["summary": ["s"], "blockers": ["none"]])
            }
        })
        let outcome = try await ReportFixtures.pipeline(backend, catalog: catalog)
            .run(transcript: "[00:00:01] You: Yesterday I fixed the build.")
        XCTAssertEqual(outcome.report.scenario, "standup")
        XCTAssertEqual(outcome.report.scenarioTitle, "Stand-up")
        XCTAssertEqual(outcome.report.sections.map(\.id), ["summary", "blockers"])
        XCTAssertTrue(backend.calls(.cheap)[0].system.contains("- standup: A daily stand-up."))
        XCTAssertTrue(backend.calls(.cheap)[0].schema.contains("\"standup\""), "the schema's enum lists it")
        XCTAssertTrue(backend.calls(.normal)[0].system.contains("Fill blockers."))
        XCTAssertTrue(backend.calls(.normal)[0].system.contains("Be brief."))
        XCTAssertEqual(backend.searches.count, 0)

        // And it can be forced by name, like a built-in one.
        let forced = try await ReportFixtures.pipeline(backend, catalog: catalog)
            .run(transcript: "[00:00:01] You: Hi", forcedScenario: "standup")
        XCTAssertEqual(forced.report.scenario, "standup")
    }

    func testAUserTemplateWithAConceptsSectionGetsTheSearch() async throws {
        try write(
            "study.json",
            try json(
                template(name: "study", sections: [spec("summary", kind: .prose), spec("terms", kind: .concepts)])))
        let catalog = ScenarioCatalog.load(userDirectory: dir).catalog
        let backend = ScriptedBackend(
            onComplete: { call in
                call.tier == .frontier
                    ? Replies.review(["terms": ["entropy"]]) : Replies.sections(["terms": ["entropy"]])
            },
            onSearch: { _ in Replies.concepts([("entropy", "disorder", [("Ref", "https://example.org/entropy")])]) })
        let outcome = try await ReportFixtures.pipeline(backend, catalog: catalog)
            .run(transcript: "[00:00:01] You: Hi", forcedScenario: "study")
        XCTAssertEqual(backend.searches, [["entropy"]])
        XCTAssertEqual(items(outcome.report, "terms").first?.sources?.first?.url, "https://example.org/entropy")
    }

    func testTheSchemaFollowsTheTemplate() throws {
        let t = try XCTUnwrap(ScenarioCatalog.builtIn.template(named: "interview"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(SummaryPipeline.sectionsSchema(t, review: false).utf8))
                as? [String: Any])
        let props = try XCTUnwrap(object["properties"] as? [String: Any])
        let sections = try XCTUnwrap((props["sections"] as? [String: Any])?["required"] as? [String])
        XCTAssertEqual(sections, t.sections.map(\.id))
        XCTAssertNil(props["changes"])
        let review = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(SummaryPipeline.sectionsSchema(t, review: true).utf8))
                as? [String: Any])
        XCTAssertNotNil((review["properties"] as? [String: Any])?["changes"])
        XCTAssertEqual(review["additionalProperties"] as? Bool, false)
    }
}

/// The invented fixtures behind the committed snapshots, `quality-compare.sh --full` and
/// `live-report.sh` hold together.
final class ReportFixtureTests: XCTestCase {

    private var scenarioDirectory: String {
        ReportFixtures.fixturesRoot.appendingPathComponent("scenarios").path
    }

    private let lineFormat = try! NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2}\] [^:\n]{1,40}: .+$"#)

    private func isInventedLine(_ line: String) -> Bool {
        lineFormat.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    func testThereIsOneScenarioFixtureForEachScenarioWithFactsAndAValidKind() throws {
        let fixtures = try RedactionFixture.load(directory: scenarioDirectory)
        XCTAssertEqual(fixtures.map(\.kind).sorted(), ReportFixtures.scenarios.sorted())
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count, "ids are unique")
        for f in fixtures {
            XCTAssertNotNil(ScenarioCatalog.builtIn.template(named: f.kind), f.id)
            XCTAssertGreaterThanOrEqual(f.facts?.count ?? 0, 5, "\(f.id) needs facts to score")
            XCTAssertTrue((f.facts ?? []).allSatisfy { !$0.isEmpty && $0.allSatisfy { !$0.isEmpty } }, f.id)
            XCTAssertEqual(
                f.factsKept(in: f.text).kept, f.facts?.count,
                "\(f.id): every fact is in its own transcript: \(f.factsKept(in: f.text).missing)")
            XCTAssertFalse(f.formatted.isEmpty, f.id)
        }
    }

    func testEveryScenarioTranscriptIsInTheLineFormatAndTwoToFiveMinutesLong() throws {
        for f in try RedactionFixture.load(directory: scenarioDirectory) {
            let lines = f.text.split(separator: "\n").map(String.init)
            XCTAssertGreaterThanOrEqual(lines.count, 10, f.id)
            for line in lines { XCTAssertTrue(isInventedLine(line), "\(f.id): \(line)") }
            let parsed = TranscriptParser.parse(f.text)
            XCTAssertEqual(parsed.count, lines.count, "\(f.id): the parser reads every line")
            let last = parsed.last?.start ?? 0
            XCTAssertTrue((120...300).contains(last), "\(f.id) ends at \(last) s")
        }
    }

    func testTheFormattedValuesAreCaughtByTheRedactorAndAreInventedOnes() throws {
        for f in try RedactionFixture.load(directory: scenarioDirectory) {
            let result = Redactor.redact(f.text)
            for value in f.formatted {
                XCTAssertTrue(result.tokens.values.contains { $0.contains(value) }, "\(f.id): \(value) is not redacted")
                XCTAssertFalse(result.text.contains(value), "\(f.id): \(value) survives")
            }
            for email in result.tokens.values.filter({ $0.contains("@") }) {
                XCTAssertTrue(email.hasSuffix("@example.com"), "\(f.id): \(email) is not an example.com address")
            }
            for phone in result.tokens.values.filter({ $0.hasPrefix("+") }) {
                XCTAssertTrue(phone.contains("555"), "\(f.id): \(phone)")
            }
        }
    }

    func testTheLiveTranscriptsAreInventedAndInTheLineFormat() throws {
        for (name, needles) in [("meeting", ["owner", "decision"]), ("therapy", ["defusion", "values", "goal"])] {
            let url = ReportFixtures.fixturesRoot.appendingPathComponent("live/\(name).txt")
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n").map(String.init)
            XCTAssertGreaterThanOrEqual(lines.count, 14, name)
            for line in lines { XCTAssertTrue(isInventedLine(line), "\(name): \(line)") }
            XCTAssertGreaterThanOrEqual(TranscriptParser.parse(text).last?.start ?? 0, 180, "\(name) runs for minutes")
            for needle in needles { XCTAssertTrue(text.lowercased().contains(needle), "\(name) lacks \(needle)") }
            let redacted = Redactor.redact(text)
            for value in redacted.tokens.values where value.contains("@") {
                XCTAssertTrue(value.hasSuffix("@example.com"), value)
            }
        }
    }

    func testEveryScenarioFolderHoldsTheRecordedRepliesTheTestsNeed() throws {
        for name in ReportFixtures.scenarios {
            let template = try XCTUnwrap(ScenarioCatalog.builtIn.template(named: name))
            for file in [
                "transcript.txt", "classify.json", "sections.json", "review.json", "expected.html", "expected.md",
            ] {
                XCTAssertTrue(ReportFixtures.exists(name, file), "\(name)/\(file)")
            }
            XCTAssertEqual(
                ReportFixtures.exists(name, "concepts.json"), template.conceptSection != nil,
                "\(name): concepts.json only where there is a concepts section")
            let classify = try XCTUnwrap(ModelJSON.object(from: try ReportFixtures.read(name, "classify.json")))
            XCTAssertEqual(classify["scenario"] as? String, name)
            for file in ["sections.json", "review.json"] {
                let decoded = SummaryPipeline.decodeSections(try ReportFixtures.read(name, file), template: template)
                XCTAssertNotNil(decoded, "\(name)/\(file) reads against its template")
                XCTAssertEqual(
                    decoded?.sections.keys.sorted(), template.sections.map(\.id).sorted(),
                    "\(name)/\(file) has every section")
            }
            XCTAssertFalse(try ReportFixtures.read(name, "review.json").isEmpty)
            let text = try ReportFixtures.read(name, "transcript.txt")
            for email in Redactor.redact(text).tokens.values.filter({ $0.contains("@") }) {
                XCTAssertTrue(email.hasSuffix("@example.com"), "\(name): \(email)")
            }
        }
    }
}
