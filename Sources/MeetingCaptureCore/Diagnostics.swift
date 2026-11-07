import Foundation

// Checks that spend subscription usage. Only `scripts/check.sh --live` and
// `scripts/quality-compare.sh` start them, always on invented text.

/// One real, small call per logged-in CLI and tier, plus one concept search.
enum LiveCheck {

    private static let schema =
        #"{"type":"object","properties":{"fruit":{"type":"string"},"count":{"type":"integer"}},"required":["fruit","count"],"additionalProperties":false}"#

    static func run(config: Config) async -> Bool {
        let runner = CLIRunner(
            models: [.claude: config.claudeModels, .codex: config.codexModels],
            allowAPIBilling: config.allowCLIAPIBilling)
        let ledger = UsageLedger()
        var allPassed = true
        var ranAny = false

        for cli in CLIKind.allCases {
            guard await runner.availability(cli) == .ready else {
                print("\(cli.label): skipped, not ready.")
                continue
            }
            ranAny = true
            for tier in ModelTier.allCases {
                let request = CLIRequest.text(
                    tier: tier, system: "Reply with the requested JSON.",
                    input: "There are two apples on the table. Give the fruit and how many.", schema: schema)
                do {
                    guard try ledger.reserve(cli, cap: config.dailyCLICallCap) else {
                        print("\(cli.label) \(tier.rawValue): skipped, daily cap reached.")
                        continue
                    }
                    let result = try await runner.run(request, on: cli)
                    let valid = schemaValid(result.text)
                    let billing = result.apiKeySource ?? "n/a (login checked: ChatGPT)"
                    print(
                        "\(cli.label) \(tier.rawValue) \(result.model): schema \(valid ? "valid" : "INVALID"), billed via \(billing)"
                    )
                    if let limit = result.rateLimit { try? ledger.record(limit: limit, for: cli) }
                    let badSource = cli == .claude && result.apiKeySource != "none"
                    if !valid || badSource { allPassed = false }
                } catch {
                    print("\(cli.label) \(tier.rawValue): FAILED, \(error.localizedDescription)")
                    allPassed = false
                }
            }
            do {
                guard try ledger.reserve(cli, cap: config.dailyCLICallCap) else { continue }
                let search = try await runner.run(
                    try .conceptSearch(tier: .cheap, concepts: ["cognitive defusion"]), on: cli)
                print("\(cli.label) search: \(search.webSearchCount) tool-use events")
                if search.webSearchCount == 0 { allPassed = false }
            } catch {
                print("\(cli.label) search: FAILED, \(error.localizedDescription)")
                allPassed = false
            }
        }
        if !ranAny {
            print("No CLI is ready, so nothing was checked.")
            return false
        }
        return allPassed
    }

    static func schemaValid(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["fruit"] is String && json["count"] is Int
    }
}

/// One invented transcript with its labelled values, in `Tests/Fixtures/redaction/`.
struct RedactionFixture: Decodable {
    let id: String
    let kind: String
    let text: String
    /// Values that must not survive redaction.
    let formatted: [String]
    /// Spoken emails, which must not survive either.
    let spoken: [String]?
    /// Known limit, scored but not required.
    let names: [String]?
    /// Look-alikes that must come through untouched.
    let decoys: [String]?
    /// Each entry lists alternatives; a summary keeps the fact if it has any of them.
    let facts: [[String]]?

    /// All `*.json` arrays in a folder, in name order.
    static func load(directory: String) throws -> [RedactionFixture] {
        let dir = URL(fileURLWithPath: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        return try names.flatMap { name in
            try JSONDecoder().decode([RedactionFixture].self, from: Data(contentsOf: dir.appendingPathComponent(name)))
        }
    }

    func factsKept(in answer: String) -> (kept: Int, missing: [String]) {
        let lower = answer.lowercased()
        var kept = 0
        var missing: [String] = []
        for alternatives in facts ?? [] {
            if alternatives.contains(where: { lower.contains($0.lowercased()) }) {
                kept += 1
            } else {
                missing.append(alternatives[0])
            }
        }
        return (kept, missing)
    }
}

/// D-19: the same transcripts with and without regex, with a blind frontier rating.
/// `--redaction` compares the sections step alone (M2); `--full` runs the whole
/// report pipeline for each scenario (M4). Results go in `dev/evidence/`.
enum QualityCompare {

    enum Mode: String { case redaction, full }

    private static let ratingSchema =
        #"{"type":"object","properties":{"accuracy_a":{"type":"integer"},"usefulness_a":{"type":"integer"},"accuracy_b":{"type":"integer"},"usefulness_b":{"type":"integer"},"note":{"type":"string"}},"required":["accuracy_a","usefulness_a","accuracy_b","usefulness_b","note"],"additionalProperties":false}"#

    private static let ratingPrompt = """
        You compare two summaries of one transcript. Rate each from 1 to 5 for accuracy (faithful to the transcript, nothing invented) and usefulness (someone who missed it could act on it). A placeholder such as <EMAIL_1> left in a summary counts against it. If you can't tell, say so in the note. Reply with the requested JSON.
        """

    private static let sectionRatingPrompt = """
        You compare two reports on one transcript, section by section. For each section id, rate report A and report B from 1 to 5 for accuracy (faithful to the transcript, nothing invented) and usefulness. A placeholder such as <EMAIL_1> left in a report counts against it. An empty section is fine when the transcript has nothing for it. If you can't tell, say so in the note. Reply with the requested JSON.
        """

    private static func sectionRatingSchema(_ ids: [String]) -> String {
        let pair: [String: Any] = [
            "type": "object",
            "properties": ["a": ["type": "integer"], "b": ["type": "integer"], "note": ["type": "string"]],
            "required": ["a", "b", "note"], "additionalProperties": false,
        ]
        var props: [String: Any] = [:]
        for id in ids { props[id] = pair }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "sections": [
                    "type": "object", "properties": props, "required": ids, "additionalProperties": false,
                ]
            ],
            "required": ["sections"], "additionalProperties": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Calls one fixture costs, at most, before retries.
    static func plannedCalls(_ fixture: RedactionFixture, mode: Mode, catalog: ScenarioCatalog) -> Int {
        switch mode {
        case .redaction: return 2 + 1
        case .full:
            let concepts = catalog.template(named: fixture.kind)?.conceptSection != nil ? 1 : 0
            return 2 * (3 + concepts) + 1
        }
    }

    static func run(
        mode: Mode = .redaction, fixturesDirectory: String, outputPath: String, config: Config, primary: CLIKind?,
        ledger: UsageLedger = UsageLedger()
    ) async -> Bool {
        let fixtures: [RedactionFixture]
        do {
            fixtures = try RedactionFixture.load(directory: fixturesDirectory).filter { !($0.facts ?? []).isEmpty }
        } catch {
            print("Couldn't read fixtures: \(error.localizedDescription)")
            return false
        }
        let catalog = ScenarioCatalog.builtIn
        let cli = primary ?? config.primaryCLI
        // Retries can add a few more, so leave a margin of a fifth.
        let planned = fixtures.reduce(0) { $0 + plannedCalls($1, mode: mode, catalog: catalog) }
        let withMargin = planned + planned / 5 + 1
        let used = (try? ledger.count(cli)) ?? 0
        print(
            "Planned: about \(planned) calls on \(cli.label) (\(withMargin) with retries); \(used) used today of \(config.dailyCLICallCap)."
        )
        if used + withMargin > config.dailyCLICallCap {
            print("That would pass today's cap of \(config.dailyCLICallCap), so nothing was run.")
            return false
        }
        let router = SummaryRoute.makeRouter(config: config, primary: primary)
        guard await router.hasReadyCLI() else {
            print("No CLI is ready, so nothing was compared.")
            return false
        }
        let backend = CLISummaryBackend(router: router)
        switch mode {
        case .redaction:
            return await runRedaction(fixtures, backend: backend, router: router, cli: cli, outputPath: outputPath)
        case .full:
            return await runFull(fixtures, backend: backend, router: router, cli: cli, outputPath: outputPath)
        }
    }

    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func write(_ doc: String, to path: String) -> Bool {
        do {
            try doc.write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(path)")
            return true
        } catch {
            print("Couldn't write \(path): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Sections step only (M2)

    private static func runRedaction(
        _ fixtures: [RedactionFixture], backend: CLISummaryBackend, router: LLMRouter, cli: CLIKind,
        outputPath: String
    ) async -> Bool {
        var rows: [String] = []
        var problems: [String] = []
        var totals = (kept: 0, keptRaw: 0, facts: 0, flagged: 0, sent: 0)
        var ratings = (accuracy: 0, usefulness: 0, accuracyRaw: 0, usefulnessRaw: 0, rated: 0)

        for fixture in fixtures {
            let scenario = ScenarioCatalog.builtIn.template(named: fixture.kind)?.name ?? ScenarioCatalog.fallbackName
            print("… \(fixture.id)")
            do {
                func pipeline(_ redaction: Bool) -> SummaryPipeline {
                    var p = SummaryPipeline(backend: backend, redaction: redaction)
                    p.searchConcepts = false
                    p.review = false
                    return p
                }
                let plain = ReportRenderer.markdown(
                    try await pipeline(false).run(transcript: fixture.text, forcedScenario: scenario).report)
                let redactedOutcome = try await pipeline(true).run(transcript: fixture.text, forcedScenario: scenario)
                let redacted = ReportRenderer.markdown(redactedOutcome.report)

                let keptRaw = fixture.factsKept(in: plain)
                let kept = fixture.factsKept(in: redacted)
                let lost = keptRaw.kept > kept.kept ? kept.missing.filter { !keptRaw.missing.contains($0) } : []
                let sentText = Redactor.redact(fixture.text).text
                let sent = fixture.formatted.filter { sentText.contains($0) }.count
                totals.kept += kept.kept
                totals.keptRaw += keptRaw.kept
                totals.facts += fixture.facts?.count ?? 0
                totals.flagged += redactedOutcome.flaggedTokens.count
                totals.sent += sent
                if !lost.isEmpty { problems.append("\(fixture.id): with regex lost \(lost.joined(separator: ", "))") }
                if !redactedOutcome.flaggedTokens.isEmpty {
                    problems.append(
                        "\(fixture.id): tokens not restored: \(redactedOutcome.flaggedTokens.joined(separator: ", "))")
                }

                // Blind: the rater sees A and B in random order, never which is which.
                let redactedIsA = Bool.random()
                let (a, b) = redactedIsA ? (redacted, plain) : (plain, redacted)
                let rated = try await router.call(
                    .text(
                        tier: .frontier, system: ratingPrompt,
                        input: "TRANSCRIPT:\n\(fixture.text)\n\nSUMMARY A:\n\(a)\n\nSUMMARY B:\n\(b)",
                        schema: ratingSchema))
                var scoreText = "unrated"
                if let json = ModelJSON.object(from: rated.text),
                    let aa = json["accuracy_a"] as? Int, let ua = json["usefulness_a"] as? Int,
                    let ab = json["accuracy_b"] as? Int, let ub = json["usefulness_b"] as? Int
                {
                    let (acc, use, accRaw, useRaw) = redactedIsA ? (aa, ua, ab, ub) : (ab, ub, aa, ua)
                    ratings.accuracy += acc
                    ratings.usefulness += use
                    ratings.accuracyRaw += accRaw
                    ratings.usefulnessRaw += useRaw
                    ratings.rated += 1
                    scoreText = "\(acc)/\(use) vs \(accRaw)/\(useRaw)"
                }
                rows.append(
                    "| \(fixture.id) | \(kept.kept)/\(fixture.facts?.count ?? 0) | \(keptRaw.kept)/\(fixture.facts?.count ?? 0) | \(sent) | \(redactedOutcome.flaggedTokens.count) | \(scoreText) |"
                )
            } catch {
                print("\(fixture.id): stopped, \(error.localizedDescription)")
                problems.append("\(fixture.id): didn't finish: \(error.localizedDescription)")
                rows.append("| \(fixture.id) | not run | not run | | | |")
            }
        }

        var doc = "# Answer quality with and without regex, \(dateString())\n\n"
        doc +=
            "Invented transcripts, sections step only on \(cli.label)'s normal tier. Ratings are blind, by the frontier tier: accuracy/usefulness out of 5, with regex vs without. Small sample, so read this as direction, not proof.\n\n"
        doc +=
            "| Transcript | Facts, with regex | Facts, without | Formatted values sent | Tokens not restored | Rating |\n|---|---|---|---|---|---|\n"
        doc += rows.joined(separator: "\n") + "\n\n"
        doc +=
            "**Totals:** facts \(totals.kept)/\(totals.facts) with regex, \(totals.keptRaw)/\(totals.facts) without; \(totals.sent) formatted values sent with regex; \(totals.flagged) tokens not restored.\n\n"
        if ratings.rated > 0 {
            let n = Double(ratings.rated)
            doc += String(
                format: "**Mean rating over %d:** with regex %.2f accuracy, %.2f usefulness; without %.2f, %.2f.\n\n",
                ratings.rated, Double(ratings.accuracy) / n, Double(ratings.usefulness) / n,
                Double(ratings.accuracyRaw) / n, Double(ratings.usefulnessRaw) / n)
        }
        doc +=
            problems.isEmpty
            ? "**Losses:** none.\n" : "**Problems:**\n" + problems.map { "- \($0)" }.joined(separator: "\n") + "\n"
        for note in router.notes { doc += "\nNote: \(note)\n" }
        return write(doc, to: outputPath) && problems.isEmpty
    }

    // MARK: - Full pipeline, per scenario (M4)

    private static func sectionsText(_ report: Report) -> [String: String] {
        var out: [String: String] = [:]
        for section in report.sections {
            let single = Report(
                topic: report.topic, scenario: report.scenario, scenarioTitle: report.scenarioTitle,
                createdAt: report.createdAt, durationSeconds: 0, language: "", models: report.models,
                reviewed: true, notices: [], sections: [section], reviewChanges: [], transcript: [])
            out[section.id] = ReportRenderer.markdown(single)
        }
        return out
    }

    private static func unsureCount(_ report: Report) -> Int {
        report.sections.reduce(0) { $0 + $1.items.filter(\.isUnsure).count }
    }

    private static let leftoverToken = try! NSRegularExpression(pattern: "<[A-Z_]+_\\d+>")

    private static func leftoverTokens(_ text: String) -> Int {
        leftoverToken.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func runFull(
        _ fixtures: [RedactionFixture], backend: CLISummaryBackend, router: LLMRouter, cli: CLIKind,
        outputPath: String
    ) async -> Bool {
        var rows: [String] = []
        var sectionRows: [String] = []
        var problems: [String] = []
        var worse: [String] = []

        for fixture in fixtures {
            print("… \(fixture.id)")
            do {
                let plain = try await SummaryPipeline(backend: backend, redaction: false).run(transcript: fixture.text)
                    .report
                let redactedOutcome = try await SummaryPipeline(backend: backend, redaction: true)
                    .run(transcript: fixture.text)
                let redacted = redactedOutcome.report
                let plainMD = ReportRenderer.markdown(plain)
                let redactedMD = ReportRenderer.markdown(redacted)

                func coverage(_ r: Report) -> String {
                    "\(r.sections.filter { !$0.items.isEmpty }.count)/\(r.sections.count)"
                }
                let keptRaw = fixture.factsKept(in: plainMD)
                let kept = fixture.factsKept(in: redactedMD)
                let lost = kept.missing.filter { !keptRaw.missing.contains($0) }
                if !lost.isEmpty { problems.append("\(fixture.id): with regex lost \(lost.joined(separator: ", "))") }
                let sameScenario = plain.scenario == redacted.scenario
                let expected = redacted.scenario == fixture.kind && plain.scenario == fixture.kind
                if !expected {
                    problems.append(
                        "\(fixture.id): expected \(fixture.kind), got \(redacted.scenario) with regex, \(plain.scenario) without"
                    )
                }
                let sameTopic =
                    plain.topic.lowercased().trimmingCharacters(in: .whitespaces)
                    == redacted.topic.lowercased().trimmingCharacters(in: .whitespaces)
                let tokensLeft = leftoverTokens(redactedMD)
                let tokensOK = redactedOutcome.flaggedTokens.isEmpty && tokensLeft == 0
                if !tokensOK {
                    problems.append(
                        "\(fixture.id): \(redactedOutcome.flaggedTokens.count) token(s) flagged, \(tokensLeft) left in the report"
                    )
                }

                // Blind per-section rating, only when both runs used the same template.
                var ratingText = "not rated (scenarios differ)"
                if sameScenario {
                    let ids = redacted.sections.map(\.id)
                    let redactedIsA = Bool.random()
                    let (a, b) = redactedIsA ? (redacted, plain) : (plain, redacted)
                    let aText = sectionsText(a)
                    let bText = sectionsText(b)
                    var input = "TRANSCRIPT:\n\(fixture.text)\n"
                    for id in ids {
                        input +=
                            "\n=== SECTION \(id) ===\nREPORT A:\n\(aText[id] ?? "")\nREPORT B:\n\(bText[id] ?? "")\n"
                    }
                    let rated = try await router.call(
                        .text(
                            tier: .frontier, system: sectionRatingPrompt, input: input, schema: sectionRatingSchema(ids)
                        ))
                    if let json = ModelJSON.object(from: rated.text), let s = json["sections"] as? [String: Any] {
                        var cells: [String] = []
                        for id in ids {
                            guard let pair = s[id] as? [String: Any], let ra = pair["a"] as? Int,
                                let rb = pair["b"] as? Int
                            else {
                                cells.append("\(id) ?")
                                continue
                            }
                            let (withRegex, without) = redactedIsA ? (ra, rb) : (rb, ra)
                            cells.append("\(id) \(withRegex)/\(without)")
                            sectionRows.append(
                                "| \(fixture.id) | \(id) | \(withRegex) | \(without) | \(pair["note"] as? String ?? "") |"
                            )
                            if withRegex < without {
                                worse.append("\(fixture.id) · \(id): \(withRegex) with regex, \(without) without")
                            }
                        }
                        ratingText = cells.joined(separator: ", ")
                    } else {
                        ratingText = "unrated"
                    }
                }
                rows.append(
                    "| \(fixture.id) | \(fixture.kind) | \(redacted.scenario) / \(plain.scenario) | \(sameTopic ? "same" : "differs") | \(coverage(redacted)) / \(coverage(plain)) | \(kept.kept)/\(keptRaw.kept) of \(fixture.facts?.count ?? 0) | \(tokensOK ? "yes" : "no") | \(unsureCount(redacted)) / \(unsureCount(plain)) | \(redacted.reviewed && plain.reviewed ? "both" : "not both") |"
                )
                print("  topics: \(redacted.topic) / \(plain.topic)")
            } catch {
                print("\(fixture.id): stopped, \(error.localizedDescription)")
                problems.append("\(fixture.id): didn't finish: \(error.localizedDescription)")
                rows.append("| \(fixture.id) | \(fixture.kind) | not run | | | | | | |")
            }
        }

        var doc = "# Report quality with and without regex, full pipeline, \(dateString())\n\n"
        doc +=
            "Invented transcripts, one per scenario, on \(cli.label): classify, sections, concepts and frontier review, run with regex and without. Each cell is with regex / without. Section ratings are blind, by the frontier tier, 1 to 5. Small sample, so read this as direction, not proof.\n\n"
        doc +=
            "| Transcript | Expected | Scenario | Topic | Sections filled | Facts kept | Tokens restored | Unsure items | Reviewed |\n|---|---|---|---|---|---|---|---|---|\n"
        doc += rows.joined(separator: "\n") + "\n\n"
        doc +=
            "## Section ratings\n\n| Transcript | Section | With regex | Without | Rater's note |\n|---|---|---|---|---|\n"
        doc += sectionRows.joined(separator: "\n") + "\n\n"
        doc +=
            worse.isEmpty
            ? "**Sections rated worse with regex:** none.\n\n"
            : "**Sections rated worse with regex (the user sees these before merge):**\n"
                + worse.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        doc +=
            problems.isEmpty
            ? "**Problems:** none.\n" : "**Problems:**\n" + problems.map { "- \($0)" }.joined(separator: "\n") + "\n"
        for note in router.notes { doc += "\nNote: \(note)\n" }
        return write(doc, to: outputPath) && problems.isEmpty
    }
}
