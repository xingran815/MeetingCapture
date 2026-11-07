import Foundation

// Scenario templates are data (spec 04): one JSON document each. The six built-in
// ones live below as JSON text, because `install.sh` copies only the binary and an
// SPM resource bundle would be left behind. A JSON file dropped into
// `~/.config/MeetingCapture/scenarios/` adds a scenario, or replaces a built-in one
// of the same name, with no code change (D-82).

struct ScenarioTemplate: Codable, Equatable {
    let name: String
    let title: String
    /// What the classifier reads to recognise this scenario.
    let description: String
    /// Extra rules for every step of this scenario, such as the therapy rules.
    let rules: [String]
    let sections: [SectionSpec]

    struct SectionSpec: Codable, Equatable {
        let id: String
        let title: String
        let kind: SectionKind
        /// What the model puts in this section, item by item.
        let instructions: String
        /// A fixed line shown under the heading.
        let note: String?
    }

    var conceptSection: SectionSpec? { sections.first { $0.kind == .concepts } }

    private static let namePattern = "^[a-z][a-z0-9_]{0,30}$"

    /// Why a template can't be used, or nil if it can.
    func problem() -> String? {
        func ok(_ s: String) -> Bool { s.range(of: Self.namePattern, options: .regularExpression) != nil }
        if !ok(name) { return "its name must be lowercase letters, digits or _" }
        if title.isEmpty || title.count > 60 { return "its title must be 1 to 60 characters" }
        if sections.isEmpty || sections.count > 12 { return "it needs 1 to 12 sections" }
        if Set(sections.map(\.id)).count != sections.count { return "two sections share an id" }
        if let bad = sections.first(where: { !ok($0.id) }) {
            return "section id \"\(bad.id)\" isn't lowercase letters, digits or _"
        }
        if sections.contains(where: { $0.title.isEmpty || $0.title.count > 80 }) {
            return "a section title must be 1 to 80 characters"
        }
        if sections.filter({ $0.kind == .concepts }).count > 1 { return "it has more than one concepts section" }
        return nil
    }
}

struct ScenarioCatalog {
    let templates: [ScenarioTemplate]

    static let fallbackName = "general"

    var names: [String] { templates.map(\.name) }

    func template(named name: String) -> ScenarioTemplate? {
        templates.first { $0.name == name.lowercased() }
    }

    var general: ScenarioTemplate { template(named: Self.fallbackName) ?? Self.builtInGeneral }

    static var userDirectory: URL {
        AppHome.url().appendingPathComponent(".config/MeetingCapture/scenarios")
    }

    static var builtIn: ScenarioCatalog { ScenarioCatalog(templates: builtInTemplates) }

    /// Built-ins plus any valid `*.json` in `directory`. A file that doesn't load is
    /// skipped and named in `warnings`, never fatal.
    static func load(userDirectory directory: URL? = ScenarioCatalog.userDirectory) -> (
        catalog: ScenarioCatalog, warnings: [String]
    ) {
        var templates = builtInTemplates
        var warnings: [String] = []
        guard let directory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return (ScenarioCatalog(templates: templates), warnings) }
        for file in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let url = directory.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), data.count < 200_000,
                let template = try? JSONDecoder().decode(ScenarioTemplate.self, from: data)
            else {
                warnings.append("Scenario file \(file) isn't a valid template, so it was skipped.")
                continue
            }
            if let problem = template.problem() {
                warnings.append("Scenario file \(file) was skipped: \(problem).")
                continue
            }
            templates.removeAll { $0.name == template.name }
            templates.append(template)
        }
        return (ScenarioCatalog(templates: templates), warnings)
    }

    // MARK: - Built-in templates

    static let builtInTemplates: [ScenarioTemplate] = builtInJSON.map {
        // A broken built-in is a programming error, caught by every test run.
        try! JSONDecoder().decode(ScenarioTemplate.self, from: Data($0.utf8))
    }

    private static var builtInGeneral: ScenarioTemplate { builtInTemplates.first { $0.name == fallbackName }! }

    static let builtInJSON: [String] = [
        #"""
        {"name":"meeting","title":"Company meeting",
         "description":"A work meeting between colleagues, a team, or a company and its partners: planning, status, decisions, tasks.",
         "rules":[],
         "sections":[
          {"id":"summary","title":"Summary","kind":"prose","instructions":"Two to four sentences on what the meeting was about and where it ended up."},
          {"id":"who_said_what","title":"Who said what","kind":"bullets","instructions":"The main points, one item each, with the speaker label in `speaker`."},
          {"id":"open_questions","title":"Open questions","kind":"qa","instructions":"Questions left open. Put the question in `text` and your best answer in `answer`, with `source` \"ai\". If you don't know, set `answer` to \"I don't know\" and say why in `reason`."},
          {"id":"actions","title":"Actions and to-dos","kind":"actions","instructions":"Tasks that were agreed, with `owner` and `due` only if they were said. Leave them empty otherwise."},
          {"id":"insights","title":"AI insights: what you can do","kind":"insights","instructions":"Your own practical suggestions for the user, with `source` \"ai\". Keep them grounded in what was said.","note":"Suggestions from the AI, not things that were said."}
         ]}
        """#,
        #"""
        {"name":"therapy","title":"Therapy session",
         "description":"A one-to-one therapy or counselling session: a therapist or counsellor and a client, about emotional or psychological support.",
         "rules":[
          "Be warm, respectful and non-judgemental. This is sensitive, confidential personal material.",
          "Do not diagnose. Do not give medical advice. Do not take sides in any conflict described; the transcript is one account.",
          "Keep the therapist's own words for named concepts, metaphors and techniques.",
          "The transcript is automatic and may have misheard words or wrong speaker labels. Read it charitably and never quote garbled text."
         ],
         "sections":[
          {"id":"summary","title":"Summary","kind":"prose","instructions":"A warm, short account of what the client brought and the thread of the session."},
          {"id":"issues","title":"Issues raised by the client","kind":"bullets","instructions":"One item per issue the client raised, in plain words."},
          {"id":"suggestions","title":"Therapist's suggestions and inspirations","kind":"bullets","instructions":"What the therapist suggested or offered, one item each. Start `text` with the issue it answers, then the suggestion. Put the therapist's own words in `quote` where they matter."},
          {"id":"todos","title":"To-dos and actions","kind":"actions","instructions":"Only what was actually suggested to try or do before next time."},
          {"id":"smart_goals","title":"SMART goals","kind":"goals","instructions":"Goals that are specific, measurable, achievable, relevant and time-bound, built only from what was agreed. Put the client's own words in `quote`. If the session gave no goal, leave this empty."},
          {"id":"concepts","title":"Concepts to explore","kind":"concepts","instructions":"Each named concept, technique or framework the therapist used. `text` is the generic concept name only, such as \"cognitive defusion\", never a person's name or a personal detail. `quote` is what the therapist said about it, `answer` is what you understand it to mean, `detail` a fuller explanation."},
          {"id":"insights","title":"AI insights on each issue","kind":"insights","instructions":"Your own reflections, one per issue, with `source` \"ai\". Gentle, practical, and never a diagnosis.","note":"From the AI, not the therapist, and not clinical advice."}
         ]}
        """#,
        #"""
        {"name":"interview","title":"Interview",
         "description":"A job interview or similar assessment where one side asks questions and the user answers them.",
         "rules":["`You` is the user, the person being interviewed, unless the transcript clearly says otherwise."],
         "sections":[
          {"id":"summary","title":"Summary","kind":"prose","instructions":"What the interview was for and how it went, in two to four sentences."},
          {"id":"questions","title":"Questions asked","kind":"bullets","instructions":"Each question the interviewer asked, with the speaker label in `speaker`."},
          {"id":"answers","title":"How you answered","kind":"bullets","instructions":"A short, fair account of each answer the user gave."},
          {"id":"gaps","title":"Gaps and stronger answers","kind":"qa","instructions":"Where an answer was weak or missing: the gap in `text`, a stronger answer in `answer`, with `source` \"ai\"."},
          {"id":"follow_ups","title":"Follow-ups","kind":"actions","instructions":"Things to send, prepare or check after the interview."},
          {"id":"insights","title":"AI insights","kind":"insights","instructions":"Your own advice for the next round, with `source` \"ai\".","note":"Suggestions from the AI, not things that were said."}
         ]}
        """#,
        #"""
        {"name":"one_on_one","title":"One-on-one",
         "description":"A one-to-one between a manager and a report, or a mentor and a mentee: feedback, commitments, career and growth.",
         "rules":[],
         "sections":[
          {"id":"summary","title":"Summary","kind":"prose","instructions":"What the one-on-one covered, in two to four sentences."},
          {"id":"feedback","title":"Feedback given","kind":"bullets","instructions":"Feedback in either direction, with who gave it in `speaker`."},
          {"id":"commitments","title":"Commitments by each side","kind":"actions","instructions":"What each person committed to, with `owner`, and `due` only if it was said."},
          {"id":"growth","title":"Career and growth topics","kind":"bullets","instructions":"Career, skills and growth topics that came up."},
          {"id":"follow_ups","title":"Follow-ups","kind":"actions","instructions":"Things to pick up next time."},
          {"id":"insights","title":"AI insights","kind":"insights","instructions":"Your own suggestions for the user, with `source` \"ai\".","note":"Suggestions from the AI, not things that were said."}
         ]}
        """#,
        #"""
        {"name":"lecture","title":"Lecture",
         "description":"A lecture, talk, class or tutorial where one speaker mostly explains a subject.",
         "rules":[],
         "sections":[
          {"id":"summary","title":"Summary","kind":"prose","instructions":"What the lecture taught, in two to four sentences."},
          {"id":"key_concepts","title":"Key concepts","kind":"bullets","instructions":"The main ideas, one item each, as the lecturer put them."},
          {"id":"explanations","title":"Explanations and sources","kind":"concepts","instructions":"Each concept worth looking up. `text` is the generic concept name only, never a person's name or a private detail. `quote` is how the lecturer put it, `answer` what you understand it to mean, `detail` a fuller explanation."},
          {"id":"study_questions","title":"Questions to study","kind":"qa","instructions":"Questions to test understanding, each with a short `answer` and `source` \"ai\"."},
          {"id":"insights","title":"AI insights","kind":"insights","instructions":"Your own suggestions for studying this, with `source` \"ai\".","note":"Suggestions from the AI, not things that were said."}
         ]}
        """#,
        #"""
        {"name":"general","title":"General",
         "description":"Anything that isn't clearly one of the other scenarios.",
         "rules":[],
         "sections":[
          {"id":"summary","title":"Summary","kind":"prose","instructions":"What the recording was about, in two to four sentences."},
          {"id":"who_said_what","title":"Who said what","kind":"bullets","instructions":"The main points, one item each, with the speaker label in `speaker`."},
          {"id":"open_questions","title":"Open questions","kind":"qa","instructions":"Questions left open, with your best `answer` and `source` \"ai\", or \"I don't know\" and why in `reason`."},
          {"id":"actions","title":"Actions","kind":"actions","instructions":"Tasks that were agreed, with `owner` and `due` only if they were said."},
          {"id":"insights","title":"AI insights","kind":"insights","instructions":"Your own suggestions for the user, with `source` \"ai\".","note":"Suggestions from the AI, not things that were said."}
         ]}
        """#,
    ]
}
