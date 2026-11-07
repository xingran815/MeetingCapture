import Foundation

// The one path from transcript to report, used by the terminal shell and flag mode
// (spec 04). Redact, then:
//   1. classify (cheap)      → scenario, topic, language, confidence
//   2. sections (normal)     → JSON for that scenario's template
//   3. concepts (normal)     → sources, from concept names only, tools on
//   4. review (frontier)     → corrected JSON, what changed and why, transcript suggestions
// then restore tokens locally. Rendering (step 5) is `ReportRenderer`, no model.
// Steps 1 and 3 degrade; a failed step 4 ships step 2–3 marked as not reviewed.
// Nothing reaches a backend without going through here first.

struct BackendReply {
    let text: String
    /// Who answered, for the report's `models`, such as "Claude haiku".
    let model: String
}

protocol SummaryBackend: AnyObject {
    var label: String { get }
    /// Things the report should say, such as a switch to the other CLI.
    var notes: [String] { get }
    /// One call with no tools. `schema` is a JSON Schema the reply must match.
    func complete(tier: ModelTier, system: String, input: String, schema: String) async throws -> BackendReply
    /// A web search over concept names only, or nil if this backend can't search.
    func searchConcepts(_ concepts: [String], schema: String) async throws -> BackendReply?
}

/// Runs on the subscription CLIs: tools off, except the concept search, whose
/// prompt `CLIRequest.conceptSearch` builds from concept names alone.
final class CLISummaryBackend: SummaryBackend {
    let router: LLMRouter
    var notes: [String] { router.notes }
    let label = "subscription CLI"

    init(router: LLMRouter) { self.router = router }

    func complete(tier: ModelTier, system: String, input: String, schema: String) async throws -> BackendReply {
        let result = try await router.call(.text(tier: tier, system: system, input: input, schema: schema))
        return BackendReply(text: result.text, model: "\(result.cli.label) \(result.model)")
    }

    func searchConcepts(_ concepts: [String], schema: String) async throws -> BackendReply? {
        let result = try await router.call(try .conceptSearch(tier: .normal, concepts: concepts, schema: schema))
        return BackendReply(text: result.text, model: "\(result.cli.label) \(result.model)")
    }
}

/// Runs on one saved API profile. A profile has one model, so every tier uses it,
/// the schema is asked for in the prompt, and there's no concept search.
final class APISummaryBackend: SummaryBackend {
    let summarizer: Summarizer
    let notes: [String] = []
    let label: String

    init(summarizer: Summarizer, label: String) {
        self.summarizer = summarizer
        self.label = label
    }

    func complete(tier: ModelTier, system: String, input: String, schema: String) async throws -> BackendReply {
        let text = try await summarizer.complete(
            system: system
                + "\n\nReply with only one JSON object matching this JSON Schema, with no other text:\n" + schema,
            user: input)
        return BackendReply(text: text, model: summarizer.model)
    }

    func searchConcepts(_ concepts: [String], schema: String) async throws -> BackendReply? { nil }
}

struct SummaryOutcome {
    let report: Report
    let redactedValues: Int
    let flaggedTokens: [String]
    /// The topic before tokens were restored, with tokens taken out: what names the
    /// HTML file, so a redacted value never reaches a file name.
    var fileTopic: String? = nil
}

enum ReportError: Error, LocalizedError, Equatable {
    case emptyTranscript
    case malformedReply(step: String)
    case unknownScenario(String, known: [String])

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "The transcript is empty, so there's nothing to summarize."
        case .malformedReply(let step):
            return "The model's reply for the \(step) step wasn't valid JSON, twice, so no report was written."
        case .unknownScenario(let name, let known):
            return "There's no scenario called \"\(name)\". Known: \(known.joined(separator: ", "))."
        }
    }
}

struct SummaryPipeline {
    let backend: SummaryBackend
    let redaction: Bool
    var catalog: ScenarioCatalog = .builtIn
    var now: () -> Date = Date.init
    var timeZone: TimeZone = .current
    /// Off only for `quality-compare.sh --redaction`, which compares the sections step alone.
    var searchConcepts = true
    var review = true

    /// The longest field a model can put in a report. Longer text is cut, so one
    /// runaway answer can't bloat the page.
    static let maxFieldLength = 6000
    static let maxItemsPerSection = 60

    func run(transcript: String, forcedScenario: String? = nil) async throws -> SummaryOutcome {
        // A model handed nothing invents a meeting, and that spends usage too.
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReportError.emptyTranscript
        }
        var forced: ScenarioTemplate?
        if let name = forcedScenario {
            guard let template = catalog.template(named: name) else {
                throw ReportError.unknownScenario(name, known: catalog.names)
            }
            forced = template
        }

        let redacted = redaction ? Redactor.redact(transcript) : Redactor.Result(text: transcript, tokens: [:])
        let suffix = redacted.tokens.isEmpty ? "" : Redactor.tokenInstruction
        let original = TranscriptParser.parse(transcript)
        var models = Report.Models()
        var notices: [String] = []

        // 1. Classify. Any failure falls back to `general`; a full limit shows up below.
        var template = forced ?? catalog.general
        var topic = ""
        var language = ""
        if forced == nil {
            do {
                let c = try await classify(redacted.text, suffix: suffix)
                models.cheap = c.model
                topic = c.topic
                language = c.language
                if let picked = catalog.template(named: c.scenario), c.confident {
                    template = picked
                } else {
                    notices.append(
                        "The scenario wasn't clear (best guess: \(c.scenario.isEmpty ? "none" : c.scenario)), so the general template was used."
                    )
                }
            } catch {
                notices.append(
                    "The scenario couldn't be classified (\(error.localizedDescription)), so the general template was used."
                )
            }
        }

        // 2. Sections. One retry on a malformed reply, then a clear failure.
        let sectionsSchema = Self.sectionsSchema(template, review: false)
        let sectionsSystem = Self.sectionsPrompt(template, language: Self.safeLanguage(language)) + suffix
        let draft = try await withOneRetry(step: "sections") { retryNote in
            let reply = try await backend.complete(
                tier: .normal, system: sectionsSystem, input: redacted.text + retryNote, schema: sectionsSchema)
            return Self.decodeSections(reply.text, template: template).map { ($0, reply.model) }
        }
        models.normal = draft.1
        var sections = draft.0.sections
        if topic.isEmpty { topic = draft.0.topic }

        // 3. Concepts: names only go out, with tools on.
        var sources: [String: [Report.Link]] = [:]
        if searchConcepts, let spec = template.conceptSection, let items = sections[spec.id], !items.isEmpty {
            let speakers = Set(original.map(\.speaker))
            let names = items.compactMap(\.text).filter { Self.isSearchableConcept($0, speakers: speakers) }
            let skipped = items.count - names.count
            if skipped > 0 {
                notices.append(
                    "\(skipped) concept name(s) weren't looked up, because they looked like more than a generic term.")
            }
            if names.count > 8 {
                notices.append("Only the first 8 concepts were looked up; \(names.count - 8) more have no sources.")
            }
            if !names.isEmpty {
                do {
                    if let reply = try await backend.searchConcepts(Array(names.prefix(8)), schema: Self.conceptSchema)
                    {
                        let found = Self.decodeConcepts(reply.text)
                        sources = found.mapValues(\.sources)
                        sections[spec.id] = items.map { item in
                            var item = item
                            if let hit = found[Self.key(item.text)] {
                                if !hit.explanation.isEmpty, (item.detail ?? "").isEmpty {
                                    item.detail = hit.explanation
                                }
                                item.sources = hit.sources
                            }
                            return item
                        }
                        if found.isEmpty {
                            notices.append("The concept search gave nothing usable, so concepts have no sources.")
                        }
                    } else {
                        notices.append("Concept sources need a subscription CLI, so none were looked up.")
                    }
                } catch {
                    notices.append(
                        "The concept search failed (\(error.localizedDescription)), so concepts have no sources.")
                }
            }
        }

        // 4. Review by the frontier tier. A failure ships the draft, marked.
        var reviewed = false
        var changes: [Report.Change] = []
        var suggestions: [Int: String] = [:]
        let numbered = TranscriptParser.parse(redacted.text)
        if review {
            do {
                let reviewSchema = Self.sectionsSchema(template, review: true)
                let system = Self.reviewPrompt(template, language: Self.safeLanguage(language)) + suffix
                let input = Self.reviewInput(numbered: numbered, draft: sections, template: template, topic: topic)
                let result = try await withOneRetry(step: "review") { retryNote in
                    let reply = try await backend.complete(
                        tier: .frontier, system: system, input: input + retryNote, schema: reviewSchema)
                    return Self.decodeSections(reply.text, template: template).map { ($0, reply.model) }
                }
                models.frontier = result.1
                // A section the review left out keeps the draft; only an explicit
                // empty list clears one.
                for (id, items) in result.0.sections { sections[id] = items }
                changes = result.0.changes
                suggestions = result.0.suggestions
                reviewed = true
                // Sources come only from the search, never from the reviewer's memory.
                if let spec = template.conceptSection {
                    sections[spec.id] = sections[spec.id]?.map { item in
                        var item = item
                        item.sources = sources[Self.key(item.text)]
                        return item
                    }
                }
            } catch {
                notices.insert(
                    "This report wasn't reviewed by the frontier model (\(error.localizedDescription)). It's the first draft.",
                    at: 0)
            }
        } else {
            notices.insert("The frontier review was switched off for this run.", at: 0)
        }
        if !suggestions.isEmpty, numbered.count != original.count {
            notices.append("Transcript suggestions were dropped, because the lines didn't line up after redaction.")
            suggestions = [:]
        }

        var report = Report(
            topic: topic.isEmpty ? template.title : topic,
            scenario: template.name, scenarioTitle: template.title,
            createdAt: Self.isoDate(now(), timeZone: timeZone),
            durationSeconds: original.last?.start ?? 0,
            language: Self.safeLanguage(language),
            models: models, reviewed: reviewed, notices: notices,
            sections: template.sections.map { spec in
                Report.Section(
                    id: spec.id, title: spec.title, kind: spec.kind, note: spec.note,
                    items: Self.cleaned(sections[spec.id] ?? [], kind: spec.kind))
            },
            reviewChanges: changes,
            transcript: original.enumerated().map { i, entry in
                var entry = entry
                if let s = suggestions[i], !s.isEmpty, s != entry.text { entry.suggestion = Self.cut(s) }
                return entry
            })

        let fileTopic = report.topic.replacingOccurrences(
            of: #"<[A-Z]+_[0-9]+>"#, with: " ", options: .regularExpression)
        // Restore tokens everywhere a model wrote. The transcript is the original text.
        var flagged: [String] = []
        if redaction {
            report = report.mappingModelText { text in
                let restored = Redactor.restore(text, tokens: redacted.tokens)
                for f in restored.flagged where !flagged.contains(f) { flagged.append(f) }
                return restored.text
            }
        }
        if !flagged.isEmpty {
            report.notices.append(
                "Couldn't restore these tokens, so they're left as they are: \(flagged.joined(separator: ", ")).")
        }
        if !redacted.tokens.isEmpty {
            report.notices.append(
                "\(redacted.tokens.count) formatted value(s) were kept out of every request. Spoken names aren't caught."
            )
        }
        report = Self.withoutRepeatedHighlights(report)
        report.notices += backend.notes
        return SummaryOutcome(
            report: report, redactedValues: redacted.tokens.count, flaggedTokens: flagged, fileTopic: fileTopic)
    }

    private func withOneRetry<T>(step: String, _ attempt: (String) async throws -> T?) async throws -> T {
        if let value = try await attempt("") { return value }
        let note =
            "\n\n(Your previous reply wasn't valid JSON for the schema. Reply again with only the JSON object.)"
        if let value = try await attempt(note) { return value }
        throw ReportError.malformedReply(step: step)
    }

    // MARK: - Step 1

    private struct Classification {
        var scenario: String
        var topic: String
        var language: String
        var confident: Bool
        var model: String
    }

    /// The head of the transcript, plus a few lines from the middle and the end.
    static func classifierSample(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let head = String(text.prefix(4000))
        guard text.count > 6000, lines.count > 40 else { return String(text.prefix(6000)) }
        let mid = lines[lines.count / 2..<min(lines.count, lines.count / 2 + 10)]
        let end = lines.suffix(10)
        return head + "\n…\n" + mid.joined(separator: "\n") + "\n…\n" + end.joined(separator: "\n")
    }

    private func classify(_ text: String, suffix: String) async throws -> Classification {
        let schema = Self.classifySchema(catalog.names)
        let reply = try await backend.complete(
            tier: .cheap, system: Self.classifyPrompt(catalog) + suffix,
            input: Self.classifierSample(text), schema: schema)
        guard let json = ModelJSON.object(from: reply.text) else {
            throw ReportError.malformedReply(step: "classify")
        }
        return Classification(
            scenario: (json["scenario"] as? String ?? "").lowercased(),
            topic: Self.cut(json["topic"] as? String ?? "", to: 120),
            language: json["language"] as? String ?? "",
            confident: (json["confidence"] as? String ?? "unsure").lowercased() == "sure",
            model: reply.model)
    }

    // MARK: - Prompts

    static let honesty = "If you aren't sure, say so. If you don't have an answer, say you don't."

    static func classifyPrompt(_ catalog: ScenarioCatalog) -> String {
        let list = catalog.templates.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return """
            You sort recordings into scenarios. Read the transcript sample and pick the scenario that fits best:
            \(list)

            Reply with JSON: "scenario" is one of the names above; "topic" is a short title of at most 8 words in the transcript's language, with no names of people; "language" is the ISO 639-1 code of the transcript's main language; "confidence" is "sure" or "unsure". \(honesty) If none fits well, pick "general" and say "unsure".
            """
    }

    private static let kindGuide = """
        How each kind of section is filled:
        - prose: one to three items, each a paragraph in "text".
        - bullets: one point per item in "text"; "speaker" when it's someone's point.
        - actions: the task in "text", "owner" and "due" only if they were said.
        - qa: the question in "text", the answer in "answer".
        - goals: the goal in "text", the person's own words in "quote", "due" if a time was set.
        - concepts: as the section says.
        - insights: your own view in "text", "source" "ai".

        So the reader can skim, every item also has:
        - "priority": "high" for the few things the reader must not miss (decisions, deadlines, commitments, risks, what changes next), "low" for background, otherwise "normal". Keep "high" very rare: one or two items in the whole report at most, and none if nothing stands out.
        - "keywords": one or two short phrases copied exactly from this item's "text" or "answer", chosen so a reader who reads only the highlights still gets the point: who, when, what was decided, how, why. About half the items get some; never highlight general words, and never a fact already highlighted in another item. Only "prose" and "bullets" sections get keywords; every other kind gets an empty list.
        """

    static func rules(_ template: ScenarioTemplate, language: String) -> String {
        var lines = [
            "Use only what is in the transcript. Never invent names, numbers, dates, decisions or quotes.",
            "\(honesty) Mark such an item \"confidence\": \"unsure\" and give the reason in \"reason\". Otherwise \"confidence\" is \"sure\" and \"reason\" is \"\".",
            "Every item has every field; use \"\" for a field that doesn't apply.",
            "\"source\" is \"transcript\" for what was said and \"ai\" for your own view or answer.",
            "Keep speaker labels exactly as they appear in the transcript.",
            language.isEmpty
                ? "Write in the transcript's language."
                : "Write in the transcript's language (\(language)).",
            "An empty section is fine when the transcript has nothing for it.",
        ]
        lines += template.rules
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func sectionList(_ template: ScenarioTemplate) -> String {
        template.sections.map { "- \($0.id) (\($0.title), \($0.kind.rawValue)): \($0.instructions)" }
            .joined(separator: "\n")
    }

    static func sectionsPrompt(_ template: ScenarioTemplate, language: String) -> String {
        """
        You write the sections of a report on a recording of this kind: \(template.title). The user gives you the transcript, one line per turn, as [time] speaker: text.

        Sections, by id:
        \(sectionList(template))

        \(kindGuide)

        Rules:
        \(rules(template, language: language))

        Also give "topic": a short title of at most 8 words, with no names of people. Reply with the requested JSON only.
        """
    }

    static func reviewPrompt(_ template: ScenarioTemplate, language: String) -> String {
        """
        You review a draft report on a recording of this kind: \(template.title). You get the transcript with numbered lines and the draft as JSON.

        Check every item against the transcript. Fix what's wrong, remove what was invented, add what's important and missing, and mark what you can't confirm as unsure with the reason. Keep the same section ids:
        \(sectionList(template))

        \(kindGuide)

        Rules:
        \(rules(template, language: language))

        In "changes", list each change you made and why, briefly; an empty list if you changed nothing.
        In "transcriptSuggestions", propose corrected text for a line only where a word was clearly misheard, by its line number. Never change what someone meant, and never for style. Most transcripts need few or none.
        Also give "topic". Reply with the requested JSON only.
        """
    }

    static func reviewInput(
        numbered: [TranscriptEntry], draft: [String: [Report.Item]], template: ScenarioTemplate, topic: String
    ) -> String {
        let lines = numbered.enumerated().map { i, e in
            "#\(i) [\(TranscriptParser.clock(e.start))] \(e.speaker.isEmpty ? "?" : e.speaker): \(e.text)"
        }
        var sections: [String: Any] = [:]
        for spec in template.sections {
            sections[spec.id] = (draft[spec.id] ?? []).map(\.modelFields)
        }
        let object: [String: Any] = ["topic": topic, "sections": sections]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "TRANSCRIPT:\n" + lines.joined(separator: "\n") + "\n\nDRAFT REPORT:\n"
            + String(decoding: data, as: UTF8.self)
    }

    // MARK: - Schemas

    static let itemFields = [
        "text", "speaker", "owner", "due", "answer", "quote", "detail", "confidence", "reason", "source",
    ]

    static let maxKeywords = 2

    private static let itemSchema: [String: Any] = {
        var properties: [String: Any] = [:]
        for field in itemFields { properties[field] = ["type": "string"] }
        properties["confidence"] = ["type": "string", "enum": ["sure", "unsure"]]
        properties["source"] = ["type": "string", "enum": ["transcript", "ai"]]
        properties["priority"] = ["type": "string", "enum": ["high", "normal", "low"]]
        properties["keywords"] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object", "properties": properties, "required": itemFields + ["priority", "keywords"],
            "additionalProperties": false,
        ]
    }()

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func classifySchema(_ names: [String]) -> String {
        json([
            "type": "object",
            "properties": [
                "scenario": ["type": "string", "enum": names],
                "topic": ["type": "string"],
                "language": ["type": "string"],
                "confidence": ["type": "string", "enum": ["sure", "unsure"]],
            ],
            "required": ["scenario", "topic", "language", "confidence"],
            "additionalProperties": false,
        ])
    }

    static func sectionsSchema(_ template: ScenarioTemplate, review: Bool) -> String {
        var sectionProps: [String: Any] = [:]
        for spec in template.sections { sectionProps[spec.id] = ["type": "array", "items": itemSchema] }
        var properties: [String: Any] = [
            "topic": ["type": "string"],
            "sections": [
                "type": "object", "properties": sectionProps, "required": template.sections.map(\.id),
                "additionalProperties": false,
            ],
        ]
        var required = ["topic", "sections"]
        if review {
            properties["changes"] = [
                "type": "array",
                "items": [
                    "type": "object", "properties": ["what": ["type": "string"], "why": ["type": "string"]],
                    "required": ["what", "why"], "additionalProperties": false,
                ],
            ]
            properties["transcriptSuggestions"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["line": ["type": "integer"], "suggestion": ["type": "string"]],
                    "required": ["line", "suggestion"], "additionalProperties": false,
                ],
            ]
            required += ["changes", "transcriptSuggestions"]
        }
        return json([
            "type": "object", "properties": properties, "required": required, "additionalProperties": false,
        ])
    }

    static let conceptSchema: String = json([
        "type": "object",
        "properties": [
            "concepts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "explanation": ["type": "string"],
                        "sources": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": ["title": ["type": "string"], "url": ["type": "string"]],
                                "required": ["title", "url"], "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["name", "explanation", "sources"], "additionalProperties": false,
                ],
            ]
        ],
        "required": ["concepts"],
        "additionalProperties": false,
    ])

    // MARK: - Decoding

    struct DecodedSections {
        var topic: String
        var sections: [String: [Report.Item]]
        var changes: [Report.Change]
        var suggestions: [Int: String]
    }

    /// Nil when the reply isn't JSON, has no `sections` object, or has none of the
    /// template's sections. Unknown sections are dropped; missing ones are empty.
    static func decodeSections(_ text: String, template: ScenarioTemplate) -> DecodedSections? {
        guard let json = ModelJSON.object(from: text), let raw = json["sections"] as? [String: Any] else {
            return nil
        }
        let ids = template.sections.map(\.id)
        guard ids.contains(where: { raw[$0] != nil }) else { return nil }
        var sections: [String: [Report.Item]] = [:]
        for id in ids {
            guard let value = raw[id] else { continue }
            // Only long text needs a highlight to skim; actions, questions, goals, concepts
            // and insights are short already, so their items carry none (user, 2026-11-07).
            let highlights = [.prose, .bullets].contains(template.sections.first { $0.id == id }?.kind)
            guard let array = value as? [Any] else { return nil }
            var items: [Report.Item] = []
            for element in array {
                guard let object = element as? [String: Any] else { return nil }
                var decoded = item(from: object)
                if !highlights { decoded.keywords = nil }
                items.append(decoded)
            }
            sections[id] = items
        }
        let changes = (json["changes"] as? [[String: Any]] ?? []).compactMap { c -> Report.Change? in
            guard let what = c["what"] as? String, !what.isEmpty else { return nil }
            return Report.Change(what: cut(what), why: cut(c["why"] as? String ?? ""))
        }
        var suggestions: [Int: String] = [:]
        for s in json["transcriptSuggestions"] as? [[String: Any]] ?? [] {
            if let line = (s["line"] as? NSNumber)?.intValue, let text = s["suggestion"] as? String, line >= 0 {
                suggestions[line] = text
            }
        }
        return DecodedSections(
            topic: cut(json["topic"] as? String ?? "", to: 120), sections: sections, changes: changes,
            suggestions: suggestions)
    }

    private static func item(from object: [String: Any]) -> Report.Item {
        func s(_ key: String) -> String? {
            guard let v = object[key] else { return nil }
            if let str = v as? String { return str.isEmpty ? nil : cut(str) }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        var item = Report.Item(
            text: s("text"), speaker: s("speaker"), owner: s("owner"), due: s("due"), answer: s("answer"),
            quote: s("quote"), detail: s("detail"), confidence: s("confidence"), reason: s("reason"),
            source: s("source"), sources: nil)
        if let p = s("priority")?.lowercased(), ["high", "normal", "low"].contains(p) { item.priority = p }
        item.keywords = keywords(object["keywords"], in: item)
        return item
    }

    /// Only short phrases that really occur in the item's own text or answer are
    /// kept, so a highlight can never show words the item doesn't contain.
    static func keywords(_ raw: Any?, in item: Report.Item) -> [String]? {
        let haystack = [item.text, item.answer].compactMap { $0 }.joined(separator: "\n")
        var out: [String] = []
        for case let k as String in raw as? [Any] ?? [] {
            let k = k.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...60).contains(k.count), !out.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }),
                haystack.range(of: k, options: [.caseInsensitive]) != nil
            else { continue }
            out.append(k)
            if out.count == maxKeywords { break }
        }
        return out.isEmpty ? nil : out
    }

    struct FoundConcept {
        var explanation: String
        var sources: [Report.Link]
    }

    /// Keyed by `key(name)`. Only `http`/`https` links are kept.
    static func decodeConcepts(_ text: String) -> [String: FoundConcept] {
        guard let json = ModelJSON.object(from: text), let list = json["concepts"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: FoundConcept] = [:]
        for c in list {
            guard let name = c["name"] as? String, !name.isEmpty else { continue }
            let links = (c["sources"] as? [[String: Any]] ?? []).compactMap { l -> Report.Link? in
                guard let url = l["url"] as? String, ReportRenderer.safeURL(url) != nil else { return nil }
                return Report.Link(title: cut(l["title"] as? String ?? url, to: 300), url: cut(url, to: 2000))
            }
            out[key(name)] = FoundConcept(
                explanation: cut(c["explanation"] as? String ?? ""), sources: Array(links.prefix(5)))
        }
        return out
    }

    static func key(_ name: String?) -> String {
        (name ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A concept goes to the search only if it's a short generic term. Labels such
    /// as `You` and `Speaker 2` are generic; a renamed label is a person's name, so a
    /// concept containing one isn't searched (D-13).
    static func isSearchableConcept(_ name: String, speakers: Set<String>) -> Bool {
        guard (try? CLIRequest.validate(concepts: [name])) != nil else { return false }
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let concept = fold(name)
        let conceptWords = concept.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let generic = try! NSRegularExpression(pattern: #"^(You|Others|Speaker \d+.*)$"#)
        for speaker in speakers where !speaker.isEmpty {
            let ns = speaker as NSString
            if generic.firstMatch(in: speaker, range: NSRange(location: 0, length: ns.length)) != nil { continue }
            for word in fold(speaker).split(whereSeparator: { !$0.isLetter }).map(String.init) {
                // Chinese, Japanese and similar scripts don't put spaces between words,
                // so a name is found anywhere in the concept. Other scripts match whole words.
                if word.unicodeScalars.contains(where: Self.isUnspacedScript) {
                    if concept.contains(word) { return false }
                } else if word.count >= 2, conceptWords.contains(word) {
                    return false
                }
            }
        }
        return true
    }

    /// Han, kana, Hangul and Thai: scripts written without spaces between words.
    static func isUnspacedScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
            0xAC00...0xD7AF, 0x1100...0x11FF, 0x0E00...0x0E7F:
            return true
        default:
            return false
        }
    }

    // MARK: - Small helpers

    static func cut(_ s: String, to limit: Int = maxFieldLength) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    private static func cleaned(_ items: [Report.Item], kind: SectionKind) -> [Report.Item] {
        items.prefix(maxItemsPerSection).compactMap { item in
            var item = item
            if kind == .insights { item.source = "ai" }
            let empty = [item.text, item.answer, item.quote, item.detail].allSatisfy { ($0 ?? "").isEmpty }
            return empty ? nil : item
        }
    }

    static func isoDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func safeLanguage(_ code: String) -> String {
        code.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$", options: .regularExpression) != nil ? code : ""
    }
}

extension Report.Item {
    /// The fields a model writes, as they go back to the reviewer. No sources.
    var modelFields: [String: Any] {
        [
            "text": text ?? "", "speaker": speaker ?? "", "owner": owner ?? "", "due": due ?? "",
            "answer": answer ?? "", "quote": quote ?? "", "detail": detail ?? "",
            "confidence": confidence ?? "sure", "reason": reason ?? "", "source": source ?? "transcript",
            "priority": priority ?? "normal", "keywords": keywords ?? [],
        ]
    }
}

extension Report {
    /// Applies `f` to every string a model wrote: topic, items, changes and
    /// suggestions. The transcript's own text and the notices are left alone.
    func mappingModelText(_ f: (String) -> String) -> Report {
        var r = self
        func m(_ s: String?) -> String? { s.map(f) }
        r.topic = f(topic)
        r.sections = sections.map { section in
            var section = section
            section.items = section.items.map { i in
                var i = i
                i.text = m(i.text)
                i.speaker = m(i.speaker)
                i.owner = m(i.owner)
                i.due = m(i.due)
                i.answer = m(i.answer)
                i.quote = m(i.quote)
                i.detail = m(i.detail)
                i.reason = m(i.reason)
                i.keywords = i.keywords?.map(f)
                return i
            }
            return section
        }
        r.reviewChanges = reviewChanges.map { Change(what: f($0.what), why: f($0.why)) }
        r.transcript = transcript.map { e in
            var e = e
            e.suggestion = m(e.suggestion)
            return e
        }
        return r
    }
}

/// Finds the JSON object in a model's reply: the whole text, a fenced block, or the
/// span from the first `{` to the last `}`.
enum ModelJSON {
    static func object(from text: String) -> [String: Any]? {
        var candidates = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let open = text.range(of: "```") {
            var rest = text[open.upperBound...]
            if let newline = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: newline)...] }
            if let close = rest.range(of: "```") { candidates.append(String(rest[..<close.lowerBound])) }
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            candidates.append(String(text[first...last]))
        }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return object
            }
        }
        return nil
    }
}

/// Chooses the backend. API profiles are used only when asked for or when no CLI
/// is ready; a CLI that's merely full never moves a run onto API billing.
enum SummaryRoute {

    /// Flag-mode overrides, which ask for an API profile by their presence.
    struct APIOverrides {
        var profile: LLMProfile?
        var model: String?
        var baseURL: String?
        var apiKeyFlag: String?
        var isEmpty: Bool { profile == nil && model == nil && baseURL == nil && apiKeyFlag == nil }
    }

    static func makeRouter(config: Config, primary: CLIKind? = nil, ledger: UsageLedger = UsageLedger()) -> LLMRouter {
        let runner = CLIRunner(
            models: [.claude: config.claudeModels, .codex: config.codexModels],
            allowAPIBilling: config.allowCLIAPIBilling)
        return LLMRouter(
            runner: runner, ledger: ledger,
            primary: primary ?? config.primaryCLI, cap: config.dailyCLICallCap)
    }

    static func backend(
        config: Config, primary: CLIKind? = nil, overrides: APIOverrides = APIOverrides()
    ) async throws -> SummaryBackend {
        if config.llmRoute == .apiProfile || !overrides.isEmpty {
            return try apiBackend(config: config, overrides: overrides)
        }
        let router = makeRouter(config: config, primary: primary)
        if await router.hasReadyCLI() { return CLISummaryBackend(router: router) }
        // Row 4 of the provider order: no CLI, so use the chosen profile if it can run.
        if !config.llmProfiles.isEmpty {
            return try apiBackend(config: config, overrides: overrides)
        }
        // Asks the router, for its reasons.
        _ = try await router.call(.text(tier: .cheap, system: "", input: ""))
        throw LLMRouter.RouterError.noCLI([])
    }

    private static func apiBackend(config: Config, overrides: APIOverrides) throws -> SummaryBackend {
        let profile = overrides.profile ?? config.activeLLMProfile
        let baseURLString = overrides.baseURL ?? profile.baseURL
        guard Config.resolveApiKey(profileID: profile.id, flag: overrides.apiKeyFlag) != nil else {
            throw Summarizer.SummarizerError.badResponse(
                "No LLM API key for \"\(profile.displayName)\". Store one via Settings → LLM configurations, export LLM_API_KEY, or log in to the claude or codex CLI."
            )
        }
        guard let baseURL = URL(string: baseURLString) else {
            throw Summarizer.SummarizerError.badResponse("Invalid LLM base URL: \(baseURLString)")
        }
        let flag = overrides.apiKeyFlag
        let id = profile.id
        return APISummaryBackend(
            summarizer: Summarizer(
                baseURL: baseURL,
                apiKeyProvider: { Config.resolveApiKey(profileID: id, flag: flag) },
                model: overrides.model ?? profile.model,
                apiStyle: LLMProvider.apiStyle(baseURL: baseURLString, providerID: profile.providerID),
                reasoningStyle: profile.reasoningStyleOverride
                    ?? LLMProvider.reasoningStyle(baseURL: baseURLString, providerID: profile.providerID),
                reasoningEffort: profile.reasoningEffort),
            label: profile.displayName)
    }
}

extension SummaryPipeline {
    /// A fact is highlighted once per report (user, 2026-11-07): going through the
    /// sections in order, a keyword equal to, inside, or containing one already
    /// highlighted is dropped, ignoring case. The At a glance box repeats its items
    /// as they are, so it isn't counted.
    static func withoutRepeatedHighlights(_ report: Report) -> Report {
        var seen: [String] = []
        var out = report
        for s in out.sections.indices {
            for i in out.sections[s].items.indices {
                guard let keywords = out.sections[s].items[i].keywords else { continue }
                let kept = keywords.filter { k in
                    let low = k.lowercased()
                    guard !seen.contains(where: { $0.contains(low) || low.contains($0) }) else { return false }
                    seen.append(low)
                    return true
                }
                out.sections[s].items[i].keywords = kept.isEmpty ? nil : kept
            }
        }
        return out
    }
}
