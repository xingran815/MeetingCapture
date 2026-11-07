import Foundation

// M5.2 (spec 05.2, D-94): groups the user makes by hand. A new report in a group is
// written with the group's earlier reports as context. What goes out is built from an
// allow-list of report fields, never a transcript:
//
//   sent:      title (the user's, if set), scenario, section titles, item `text` and
//              `detail`, `priority`, `keywords`, with the user's edits applied; a
//              report's notes only where that report's notes switch is on
//   never:     `transcript`, item `quote`, `reviewChanges`, notices, and every other field
//
// `groups.json` lives in the output folder and names reports by base name, so a moved
// folder still works. Nothing is ever grouped automatically.

// MARK: - The groups file

/// One group the user made.
public struct ReportGroup: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Base names (`meeting_20261107_093000`) in the folder that holds `groups.json`.
    public var members: [String]
    /// On by default. Context is redacted only when this AND the global setting are on,
    /// so a group can turn redaction off for its context but never on (D-94).
    public var redactContext: Bool
    /// A pinned scenario (a therapy series stays therapy), which skips the classifier.
    public var scenario: String?

    init(
        id: String = UUID().uuidString, name: String, members: [String] = [], redactContext: Bool = true,
        scenario: String? = nil
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.redactContext = redactContext
        self.scenario = scenario
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        redactContext = try c.decodeIfPresent(Bool.self, forKey: .redactContext) ?? true
        scenario = try c.decodeIfPresent(String.self, forKey: .scenario)
    }
}

public enum GroupError: Error, LocalizedError, Equatable {
    case unreadable
    case newerFile
    case badName
    case nameTaken(String)
    case noSuchGroup
    case badMember
    case unknownScenario(String)
    case redactionOffGlobally

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "groups.json can't be read, so it was left as it is. Fix or remove it to change groups."
        case .newerFile:
            return "groups.json was written by a newer version of MeetingCapture, so this one leaves it as it is."
        case .badName: return "A group's name can't be empty or longer than \(GroupStore.maxName) characters."
        case .nameTaken(let name): return "There's already a group called \"\(name)\"."
        case .noSuchGroup: return "That group isn't there any more."
        case .badMember: return "That recording can't be put in a group."
        case .unknownScenario(let name): return "There's no scenario called \"\(name)\"."
        case .redactionOffGlobally:
            return "Redaction is off in Settings, so a group can't turn it on. Turn redaction on in Settings first."
        }
    }
}

/// `groups.json`, read and written whole. A missing file is no groups; a file that
/// can't be read throws, so a change never writes over groups it couldn't read.
enum GroupStore {
    static let fileName = "groups.json"
    static let maxName = 100

    private struct File: Codable {
        var version = 1
        var groups: [ReportGroup] = []
    }

    static func url(in dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    static func load(in dir: URL) throws -> [ReportGroup] {
        let url = url(in: dir)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { throw GroupError.unreadable }
        guard file.version <= 1 else { throw GroupError.newerFile }
        return file.groups
    }

    static func save(_ groups: [ReportGroup], in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(File(groups: groups)).write(to: url(in: dir), options: .atomic)
    }

    /// Loads, changes and saves. Nothing is written when `change` throws.
    @discardableResult
    static func change<T>(in dir: URL, _ change: (inout [ReportGroup]) throws -> T) throws -> T {
        var groups = try load(in: dir)
        let result = try change(&groups)
        try save(groups, in: dir)
        return result
    }

    /// The group a recording is in, or nil. An unreadable file reads as no group, so a
    /// report is still written, without context.
    static func group(of base: String, in dir: URL) -> ReportGroup? {
        (try? load(in: dir))?.first { $0.members.contains(base) }
    }

    static func cleanName(_ raw: String) throws -> String {
        let name = raw.replacingOccurrences(of: "\r\n", with: " ").components(separatedBy: .newlines)
            .joined(separator: " ")
        let cleaned = String(
            String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        ).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= maxName else { throw GroupError.badName }
        return cleaned
    }

    private static func checkUnique(_ name: String, in groups: [ReportGroup], except id: String? = nil) throws {
        if groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw GroupError.nameTaken(name)
        }
    }

    private static func index(of id: String, in groups: [ReportGroup]) throws -> Int {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { throw GroupError.noSuchGroup }
        return i
    }

    @discardableResult
    static func create(named raw: String, in dir: URL) throws -> ReportGroup {
        let name = try cleanName(raw)
        return try change(in: dir) { groups in
            try checkUnique(name, in: groups)
            let group = ReportGroup(name: name)
            groups.append(group)
            return group
        }
    }

    static func rename(_ id: String, to raw: String, in dir: URL) throws {
        let name = try cleanName(raw)
        try change(in: dir) { groups in
            let i = try index(of: id, in: groups)
            try checkUnique(name, in: groups, except: id)
            groups[i].name = name
        }
    }

    /// Only the group goes; its reports stay as they are.
    static func delete(_ id: String, in dir: URL) throws {
        try change(in: dir) { groups in
            let i = try index(of: id, in: groups)
            groups.remove(at: i)
        }
    }

    /// A report is in at most one group, so adding it here takes it out of any other.
    static func add(_ base: String, to id: String, in dir: URL) throws {
        guard Notebook.isPlainName(base), !base.hasSuffix(".json") else { throw GroupError.badMember }
        try change(in: dir) { groups in
            let i = try index(of: id, in: groups)
            for g in groups.indices where g != i { groups[g].members.removeAll { $0 == base } }
            if !groups[i].members.contains(base) { groups[i].members.append(base) }
        }
    }

    /// Takes a report out of whatever group has it. Nothing is written when none does.
    static func removeEverywhere(_ base: String, in dir: URL) throws {
        guard let groups = try? load(in: dir), groups.contains(where: { $0.members.contains(base) }) else { return }
        try change(in: dir) { groups in
            for g in groups.indices { groups[g].members.removeAll { $0 == base } }
        }
    }

    /// `globalRedaction` is the Settings switch: with it off, a group can't turn its own on.
    static func setRedactContext(_ id: String, _ on: Bool, globalRedaction: Bool, in dir: URL) throws {
        if on && !globalRedaction { throw GroupError.redactionOffGlobally }
        try change(in: dir) { groups in
            let i = try index(of: id, in: groups)
            groups[i].redactContext = on
        }
    }

    /// Nil unpins it, so the classifier picks again.
    static func setScenario(_ id: String, _ name: String?, catalog: ScenarioCatalog, in dir: URL) throws {
        if let name, catalog.template(named: name) == nil { throw GroupError.unknownScenario(name) }
        try change(in: dir) { groups in
            let i = try index(of: id, in: groups)
            groups[i].scenario = name?.lowercased()
        }
    }
}

// MARK: - Context from the group's other reports

/// What a report in a group gets from its group, and what the report should say about it.
struct GroupContext: Equatable {
    var groupName: String
    /// The allow-listed text, or empty when no other report could be used.
    var text: String
    /// The group's switch. Context is redacted only when this and global redaction are on.
    var redact: Bool
    /// Titles of the reports used, newest first.
    var used: [String]
    /// The reports left out, with why, newest first.
    var leftOut: [Skipped]
    /// For the report's notices.
    var notices: [String]

    struct Skipped: Equatable {
        var title: String
        var reason: LeftOut
    }

    enum LeftOut: Equatable {
        case noReport
        case later
        case overCap
        case gone

        var text: String {
            switch self {
            case .noReport: return "no report yet"
            case .later: return "recorded after this one"
            case .overCap: return "over the length limit"
            case .gone: return "its files are gone"
            }
        }
    }
}

enum GroupContextBuilder {
    /// How much context goes out, in characters, at most. About 6,000 tokens: enough
    /// for several earlier reports, small next to a long transcript. Assumed (D-94).
    static let maxCharacters = 24_000

    /// The context for the report of `base`, or nil when it isn't in a group. Only
    /// reports recorded before this one count, newest first, until the next one
    /// wouldn't fit under `maxCharacters`; it and every older one are left out.
    static func build(for base: URL, maxCharacters: Int = maxCharacters) -> GroupContext? {
        let dir = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        guard let group = GroupStore.group(of: name, in: dir) else { return nil }
        let mine = createdAt(of: base) ?? Date()

        struct Candidate {
            var title: String
            var date: Date
            var report: Report?
            var notes: String?
            var gone: Bool
        }
        var candidates: [Candidate] = []
        for member in group.members where member != name && Notebook.isPlainName(member) {
            let other = dir.appendingPathComponent(member)
            guard Notebook.recordingExists(base: other) else {
                candidates.append(Candidate(title: member, date: .distantPast, report: nil, notes: nil, gone: true))
                continue
            }
            let date = createdAt(of: other) ?? .distantPast
            guard let model = Notebook.loadReport(base: other) else {
                let title = (try? ReportEdits.load(at: ReportEdits.url(forBase: other)))?.userTitle
                candidates.append(
                    Candidate(title: title ?? member, date: date, report: nil, notes: nil, gone: false))
                continue
            }
            // The user's title and edits, as the page shows them. Unreadable edits: the model's text.
            let edits = (try? ReportEdits.load(at: ReportEdits.url(forBase: other))) ?? ReportEdits()
            let merged = Notebook.apply(edits, to: model).report
            // Notes only where that report's own switch is on (D-94).
            let notes =
                edits.sendNotesToLLM
                ? Notebook.loadNotes(base: other).map { String($0.prefix(Notebook.maxNotes)) } : nil
            candidates.append(Candidate(title: merged.topic, date: date, report: merged, notes: notes, gone: false))
        }
        candidates.sort { $0.date != $1.date ? $0.date > $1.date : $0.title < $1.title }

        var blocks: [String] = []
        var used: [String] = []
        var leftOut: [GroupContext.Skipped] = []
        var total = 0
        var full = false
        for c in candidates {
            let title = safeTitle(c.title)
            if c.gone {
                leftOut.append(.init(title: title, reason: .gone))
                continue
            }
            guard let report = c.report else {
                leftOut.append(.init(title: title, reason: .noReport))
                continue
            }
            if c.date >= mine {
                leftOut.append(.init(title: title, reason: .later))
                continue
            }
            let block = render(report, notes: c.notes, date: c.date)
            if full || total + block.count > maxCharacters {
                full = true
                leftOut.append(.init(title: title, reason: .overCap))
                continue
            }
            total += block.count
            blocks.append(block)
            used.append(title)
        }

        var notices: [String] = []
        let groupName = safeTitle(group.name)
        if used.isEmpty {
            notices.append(
                "This report is in the group \"\(groupName)\", but no other report in it was used as context.")
        } else {
            notices.append(
                "Written with context from \(used.count) earlier report(s) in the group \"\(groupName)\": "
                    + used.map { "\"\($0)\"" }.joined(separator: ", ")
                    + ". The review checked this report against its own transcript only.")
        }
        if !leftOut.isEmpty {
            notices.append(
                "Left out of the context: "
                    + leftOut.map { "\"\($0.title)\" (\($0.reason.text))" }.joined(separator: ", ") + ".")
        }
        return GroupContext(
            groupName: groupName, text: blocks.joined(separator: "\n\n"), redact: group.redactContext,
            used: used, leftOut: leftOut, notices: notices)
    }

    /// The recording's own start, from the sidecar (a re-run doesn't change it), else the
    /// report file's creation date, as the library uses.
    static func createdAt(of base: URL) -> Date? {
        if let s = RecordingSidecar.load(at: RecordingSidecar.url(forBase: base)) { return s.createdAt }
        return (try? FileManager.default.attributesOfItem(atPath: Notebook.reportURL(forBase: base).path))?[
            .creationDate] as? Date
    }

    /// One report, from the allow-list only. Every field is one line, so nothing in a
    /// field can pass for a heading, and token-shaped text is taken out, so it can't be
    /// read back as one of this run's tokens.
    static func render(_ report: Report, notes: String?, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var lines = [
            "=== EARLIER REPORT: \"\(line(report.topic))\" · \(line(report.scenarioTitle)) · recorded \(f.string(from: date)) ==="
        ]
        for section in report.sections {
            let items = section.items.filter { !($0.text ?? "").isEmpty || !($0.detail ?? "").isEmpty }
            guard !items.isEmpty else { continue }
            lines.append("## \(line(section.title))")
            for item in items {
                let mark = item.isHigh ? "[key] " : item.isLow ? "[background] " : ""
                lines.append("- \(mark)\(line(item.text ?? ""))")
                if let detail = item.detail, !detail.isEmpty { lines.append("  More: \(line(detail))") }
                let text = item.text ?? ""
                let keywords = (item.keywords ?? []).filter { text.range(of: $0, options: .caseInsensitive) != nil }
                if !keywords.isEmpty { lines.append("  Keywords: \(keywords.map(line).joined(separator: ", "))") }
            }
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## The user's own notes on that recording")
            lines.append(line(notes))
        }
        return Redactor.withoutTokens(lines.joined(separator: "\n"))
    }

    private static func line(_ s: String) -> String {
        let joined = s.replacingOccurrences(of: "\r\n", with: " ").components(separatedBy: .newlines)
            .joined(separator: " ")
        return String(
            String.UnicodeScalarView(joined.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    }

    private static func safeTitle(_ s: String) -> String {
        let one = line(s).trimmingCharacters(in: .whitespaces)
        return one.count > 120 ? String(one.prefix(120)) + "…" : one
    }
}

// MARK: - Everything a report gets besides its transcript

/// Notes, group context and a pinned scenario for the report of `base`, gathered the
/// same way for the app, the terminal and flag mode.
struct ReportInputs {
    var notes: String?
    var context: GroupContext?
    var scenario: String?
    var notices: [String] = []

    /// `flagScenario` (`--scenario`) wins over the group's pin. A pin the catalog
    /// doesn't know is ignored, with a notice, and the classifier picks.
    static func gather(base: URL, catalog: ScenarioCatalog, flagScenario: String? = nil) -> ReportInputs {
        // Notes go out only when the user turned that on for this report (D-93). Notes
        // edited outside the app skip its limit; only the limit's worth goes out.
        let notes =
            Notebook.sendsNotesToLLM(base: base)
            ? Notebook.loadNotes(base: base).map { String($0.prefix(Notebook.maxNotes)) } : nil
        var inputs = ReportInputs(notes: notes, context: GroupContextBuilder.build(for: base), scenario: flagScenario)
        if flagScenario == nil,
            let pin = GroupStore.group(of: base.lastPathComponent, in: base.deletingLastPathComponent())?.scenario
        {
            if catalog.template(named: pin) != nil {
                inputs.scenario = pin
            } else {
                inputs.notices.append(
                    "The group's pinned scenario \"\(pin)\" isn't known any more, so the scenario was classified.")
            }
        }
        return inputs
    }
}
