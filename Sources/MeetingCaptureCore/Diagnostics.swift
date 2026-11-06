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

/// D-19: the same transcripts with and without regex, on the normal tier, with a
/// blind frontier rating. Results go in `dev/evidence/`.
enum QualityCompare {

    private static let ratingSchema =
        #"{"type":"object","properties":{"accuracy_a":{"type":"integer"},"usefulness_a":{"type":"integer"},"accuracy_b":{"type":"integer"},"usefulness_b":{"type":"integer"},"note":{"type":"string"}},"required":["accuracy_a","usefulness_a","accuracy_b","usefulness_b","note"],"additionalProperties":false}"#

    private static let ratingPrompt = """
        You compare two summaries of one transcript. Rate each from 1 to 5 for accuracy (faithful to the transcript, nothing invented) and usefulness (someone who missed it could act on it). A placeholder such as <EMAIL_1> left in a summary counts against it. If you can't tell, say so in the note. Reply with the requested JSON.
        """

    static func run(fixturesDirectory: String, outputPath: String, config: Config, primary: CLIKind?) async -> Bool {
        let fixtures: [RedactionFixture]
        do {
            fixtures = try RedactionFixture.load(directory: fixturesDirectory).filter { !($0.facts ?? []).isEmpty }
        } catch {
            print("Couldn't read fixtures: \(error.localizedDescription)")
            return false
        }
        let router = SummaryRoute.makeRouter(config: config, primary: primary)
        guard await router.hasReadyCLI() else {
            print("No CLI is ready, so nothing was compared.")
            return false
        }
        let backend = CLISummaryBackend(router: router)

        var rows: [String] = []
        var problems: [String] = []
        var totals = (kept: 0, keptRaw: 0, facts: 0, flagged: 0, sent: 0)
        var ratings = (accuracy: 0, usefulness: 0, accuracyRaw: 0, usefulnessRaw: 0, rated: 0)

        for fixture in fixtures {
            let style: SummaryStyle = fixture.kind == "therapy" ? .therapy : .meeting
            print("… \(fixture.id)")
            do {
                let plain = try await SummaryPipeline(backend: backend, redaction: false)
                    .run(transcript: fixture.text, forcedStyle: style)
                let redacted = try await SummaryPipeline(backend: backend, redaction: true)
                    .run(transcript: fixture.text, forcedStyle: style)

                let keptRaw = fixture.factsKept(in: plain.markdown)
                let kept = fixture.factsKept(in: redacted.markdown)
                let lost = keptRaw.kept > kept.kept ? kept.missing.filter { !keptRaw.missing.contains($0) } : []
                let sentText = Redactor.redact(fixture.text).text
                let sent = fixture.formatted.filter { sentText.contains($0) }.count
                totals.kept += kept.kept
                totals.keptRaw += keptRaw.kept
                totals.facts += fixture.facts?.count ?? 0
                totals.flagged += redacted.flaggedTokens.count
                totals.sent += sent
                if !lost.isEmpty { problems.append("\(fixture.id): with regex lost \(lost.joined(separator: ", "))") }
                if !redacted.flaggedTokens.isEmpty {
                    problems.append(
                        "\(fixture.id): tokens not restored: \(redacted.flaggedTokens.joined(separator: ", "))")
                }

                // Blind: the rater sees A and B in random order, never which is which.
                let redactedIsA = Bool.random()
                let (a, b) = redactedIsA ? (redacted.markdown, plain.markdown) : (plain.markdown, redacted.markdown)
                let rated = try await router.call(
                    .text(
                        tier: .frontier, system: ratingPrompt,
                        input: "TRANSCRIPT:\n\(fixture.text)\n\nSUMMARY A:\n\(a)\n\nSUMMARY B:\n\(b)",
                        schema: ratingSchema))
                var scoreText = "unrated"
                if let data = rated.text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
                    "| \(fixture.id) | \(kept.kept)/\(fixture.facts?.count ?? 0) | \(keptRaw.kept)/\(fixture.facts?.count ?? 0) | \(sent) | \(redacted.flaggedTokens.count) | \(scoreText) |"
                )
            } catch {
                print("\(fixture.id): stopped, \(error.localizedDescription)")
                problems.append("\(fixture.id): didn't finish: \(error.localizedDescription)")
                rows.append("| \(fixture.id) | not run | not run | | | |")
            }
        }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        var doc = "# Answer quality with and without regex, \(f.string(from: Date()))\n\n"
        doc +=
            "Invented transcripts, normal tier on \((primary ?? config.primaryCLI).label). Ratings are blind, by the frontier tier: accuracy/usefulness out of 5, with regex vs without. Small sample, so read this as direction, not proof.\n\n"
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
        do {
            try doc.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Wrote \(outputPath)")
        } catch {
            print("Couldn't write \(outputPath): \(error.localizedDescription)")
            return false
        }
        return problems.isEmpty
    }
}
