import Foundation

// M5.1 (spec 05.1, D-93): a report is a notebook the user keeps. `ReportFiles.write`
// re-encodes `<base>.report.json` on every run, so nothing of the user's lives there.
// It lives beside it and is merged whenever a report is shown:
//
//   <base>.edits.json   the new title, content edits, the "send notes to the LLM" switch
//   <base>.notes.md     the user's notes, as written
//
// Delete moves only the recording's own listed files to the Trash, sidecar last (D-44).

// MARK: - The user's layer

/// `<base>.edits.json`. Every field is optional on decode, so an older or hand-edited
/// file still loads.
struct ReportEdits: Codable, Equatable {
    var version = 1
    /// Shown instead of the model's topic. The model's topic stays in `report.json`.
    var userTitle: String?
    /// Off by default: notes go to the model only when the user turns this on (D-93).
    var sendNotesToLLM = false
    var overrides: [ContentEdit] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        userTitle = try c.decodeIfPresent(String.self, forKey: .userTitle)
        sendNotesToLLM = try c.decodeIfPresent(Bool.self, forKey: .sendNotesToLLM) ?? false
        overrides = try c.decodeIfPresent([ContentEdit].self, forKey: .overrides) ?? []
    }

    var isEmpty: Bool { userTitle == nil && !sendNotesToLLM && overrides.isEmpty }

    static func url(forBase base: URL) -> URL { base.appendingPathExtension("edits.json") }

    /// A missing file is no edits. A file that can't be read throws, so a save never
    /// writes over edits it couldn't read.
    static func load(at url: URL) throws -> ReportEdits {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReportEdits() }
        let data = try Data(contentsOf: url)
        do { return try JSONDecoder().decode(ReportEdits.self, from: data) } catch {
            throw NotebookError.editsUnreadable(url.lastPathComponent)
        }
    }

    func save(to url: URL) throws {
        // A newer app's file could hold fields this one would drop. From the M5.1 deep review.
        guard version <= 1 else { throw NotebookError.newerEdits(url.lastPathComponent) }
        if isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One change the user made to the model's text. It keeps the text it replaced, and
/// applies only while that text still matches, so a report written again never shows
/// an edit meant for different words.
struct ContentEdit: Codable, Equatable {
    /// The section's id, such as `actions`.
    var section: String
    /// The item's position in that section when the edit was made.
    var item: Int
    var field: EditableField.Field
    /// The model's text this edit replaced.
    var original: String
    /// The user's text.
    var text: String
    /// For owner, due, answer and detail: the item's own text when the edit was made, so
    /// a short value such as "Friday" can't move to another item that happens to share
    /// it. Nil for text edits. From the M5.1 deep review.
    var itemText: String? = nil
}

public enum NotebookError: Error, LocalizedError, Equatable {
    case editsUnreadable(String)
    case noReport
    case noSuchField
    case tooLong(Int)
    case recordingInProgress
    case unfinished
    case sidecarUnreadable
    case moveFailed(String, String)
    case newerEdits(String)
    case reportChanged
    case recordingGone

    public var errorDescription: String? {
        switch self {
        case .editsUnreadable(let name):
            return "\(name) can't be read, so it was left as it is. Fix or remove it to change this report."
        case .noReport: return "This recording has no report yet."
        case .noSuchField: return "That part of the report isn't there any more."
        case .tooLong(let max): return "That's too long: at most \(max) characters."
        case .recordingInProgress: return "This recording is still being recorded or processed."
        case .unfinished:
            return
                "This recording wasn't finished, so its audio isn't listed yet. Process it first, or move its files to the Trash in Finder."
        case .sidecarUnreadable:
            return
                "This recording's file list (.mcmeta.json) can't be read, so nothing was moved. Its files are all still there."
        case .newerEdits(let name):
            return "\(name) was written by a newer version of MeetingCapture, so this one leaves it as it is."
        case .reportChanged:
            return
                "The report changed while you were editing (it was written again), so nothing was saved. Open Edit Report again to edit the new text."
        case .recordingGone:
            return "This recording's files are gone (moved to the Trash?), so nothing was saved."
        case .moveFailed(let name, let why):
            return
                "Couldn't move \(name) to the Trash (\(why)). Files after it, and the file list, were left, so the recording still lists what's there."
        }
    }
}

// MARK: - Fields the app can edit

/// One piece of a report the app offers for editing (desktop only, D-93).
public struct EditableField: Identifiable, Hashable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case text, answer, detail, owner, due

        public var label: String {
            switch self {
            case .text: return "Text"
            case .answer: return "Answer"
            case .detail: return "More detail"
            case .owner: return "Owner"
            case .due: return "Due"
            }
        }

        func get(_ item: Report.Item) -> String? {
            switch self {
            case .text: return item.text
            case .answer: return item.answer
            case .detail: return item.detail
            case .owner: return item.owner
            case .due: return item.due
            }
        }

        func set(_ item: inout Report.Item, _ value: String) {
            switch self {
            case .text: item.text = value
            case .answer: item.answer = value
            case .detail: item.detail = value
            case .owner: item.owner = value
            case .due: item.due = value
            }
        }
    }

    public var id: String { "\(section)#\(item)#\(field.rawValue)" }
    public let section: String
    public let sectionTitle: String
    public let item: Int
    public let field: Field
    /// What the page shows now, with the user's edits.
    public let current: String
    /// The model's text, which a reset goes back to.
    public let modelText: String
    public var isEdited: Bool { current != modelText }
    /// Text fields can span lines; owner and due are one line.
    public var isMultiline: Bool { field == .text || field == .answer || field == .detail }
}

// MARK: - Merging and rendering

enum Notebook {

    static let maxTitle = 200
    static let maxNotes = 100_000

    static func notesURL(forBase base: URL) -> URL { base.appendingPathExtension("notes.md") }
    static func reportURL(forBase base: URL) -> URL { base.appendingPathExtension("report.json") }

    struct Applied {
        var report: Report
        var applied: Int
        var stale: [ContentEdit]
    }

    /// The report as the user sees it: their title, and every edit whose original still
    /// matches. An edit is looked for at its place first, then at the one item in the
    /// same section whose field still has that original (the model may reorder). An
    /// edit found nowhere is stale: reported, never applied.
    static func apply(_ edits: ReportEdits, to report: Report) -> Applied {
        var r = report
        var applied = 0
        var stale: [ContentEdit] = []
        for edit in edits.overrides {
            guard let s = r.sections.firstIndex(where: { $0.id == edit.section }),
                let i = place(of: edit, in: report.sections[s])
            else {
                stale.append(edit)
                continue
            }
            edit.field.set(&r.sections[s].items[i], cut(edit.text, SummaryPipeline.maxFieldLength))
            applied += 1
        }
        if let title = edits.userTitle, !title.isEmpty { r.topic = title }
        return Applied(report: r, applied: applied, stale: stale)
    }

    /// Where an edit goes in the model's section, or nil when its original is gone.
    private static func place(of edit: ContentEdit, in section: Report.Section) -> Int? {
        func matches(_ i: Int) -> Bool {
            let item = section.items[i]
            guard edit.field.get(item) == edit.original else { return false }
            if let itemText = edit.itemText { return (item.text ?? "") == itemText }
            return true
        }
        if section.items.indices.contains(edit.item), matches(edit.item) { return edit.item }
        let hits = section.items.indices.filter(matches)
        return hits.count == 1 ? hits[0] : nil
    }

    /// Everything a page needs: the merged report, the notes, and what to tell the user.
    struct Page {
        var report: Report
        var notes: String?
        var staleEdits: Int
    }

    /// Merges `<base>.edits.json` and `<base>.notes.md` into `report`. An unreadable edits
    /// file is left alone and said in a notice, so the report still shows.
    static func page(for report: Report, base: URL) -> Page {
        var merged = report
        var stale = 0
        do {
            let edits = try ReportEdits.load(at: ReportEdits.url(forBase: base))
            let result = apply(edits, to: report)
            merged = result.report
            stale = result.stale.count
            if result.applied > 0 {
                merged.notices.append(
                    result.applied == 1
                        ? "You edited 1 part of this report." : "You edited \(result.applied) parts of this report.")
            }
            if stale > 0 {
                merged.notices.append(
                    stale == 1
                        ? "1 edit no longer matches the report, so it isn't shown. Keep or drop it in the app."
                        : "\(stale) edits no longer match the report, so they aren't shown. Keep or drop them in the app."
                )
            }
        } catch {
            merged.notices.append(error.localizedDescription)
        }
        return Page(report: merged, notes: loadNotes(base: base), staleEdits: stale)
    }

    static func loadReport(base: URL) -> Report? {
        guard let data = try? Data(contentsOf: reportURL(forBase: base)) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    /// The notes, or nil when there are none or they're only whitespace.
    static func loadNotes(base: URL) -> String? {
        guard let text = try? String(contentsOf: notesURL(forBase: base), encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    static func html(base: URL) -> String? {
        guard let report = loadReport(base: base) else { return nil }
        let page = page(for: report, base: base)
        return ReportRenderer.html(page.report, notes: page.notes)
    }

    // MARK: Changes

    /// Whether anything of the recording is still there. Writing the user's layer for a
    /// recording that was moved to the Trash would leave orphan notes or edits behind.
    static func recordingExists(base: URL) -> Bool {
        let fm = FileManager.default
        return [RecordingSidecar.url(forBase: base), reportURL(forBase: base), base.appendingPathExtension("txt")]
            .contains { fm.fileExists(atPath: $0.path) }
    }

    private static func editing(base: URL, _ change: (inout ReportEdits) throws -> Void) throws {
        guard recordingExists(base: base) else { throw NotebookError.recordingGone }
        let url = ReportEdits.url(forBase: base)
        var edits = try ReportEdits.load(at: url)
        try change(&edits)
        try edits.save(to: url)
        rerenderLatestHTML(base: base)
    }

    /// An empty title goes back to the model's topic.
    static func rename(base: URL, to raw: String) throws {
        let title = oneLine(raw)
        guard title.count <= maxTitle else { throw NotebookError.tooLong(maxTitle) }
        try editing(base: base) { $0.userTitle = title.isEmpty ? nil : title }
    }

    static func saveNotes(base: URL, _ text: String) throws {
        guard text.count <= maxNotes else { throw NotebookError.tooLong(maxNotes) }
        // From the M5.1 deep review: an open notes pane flushed after a delete put the
        // notes back on disk as an orphan.
        guard recordingExists(base: base) else { throw NotebookError.recordingGone }
        let url = notesURL(forBase: base)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        rerenderLatestHTML(base: base)
    }

    static func setSendNotesToLLM(base: URL, _ on: Bool) throws {
        try editing(base: base) { $0.sendNotesToLLM = on }
    }

    static func sendsNotesToLLM(base: URL) -> Bool {
        (try? ReportEdits.load(at: ReportEdits.url(forBase: base)))?.sendNotesToLLM ?? false
    }

    /// Every field the app offers, with the user's text where they edited it.
    static func editableFields(base: URL) -> [EditableField] {
        guard let report = loadReport(base: base) else { return [] }
        let merged = page(for: report, base: base).report
        var out: [EditableField] = []
        for (s, section) in report.sections.enumerated() {
            for (i, item) in section.items.enumerated() {
                for field in fields(for: section.kind) {
                    guard let model = field.get(item) else { continue }
                    if model.isEmpty && field != .text { continue }
                    let now = field.get(merged.sections[s].items[i]) ?? model
                    out.append(
                        EditableField(
                            section: section.id, sectionTitle: section.title, item: i, field: field, current: now,
                            modelText: model))
                }
            }
        }
        return out
    }

    private static func fields(for kind: SectionKind) -> [EditableField.Field] {
        switch kind {
        case .prose, .bullets, .insights: return [.text]
        case .actions: return [.text, .owner, .due]
        case .qa: return [.text, .answer]
        case .goals: return [.text, .due]
        case .concepts: return [.text, .answer, .detail]
        }
    }

    /// Sets each field (keyed by `EditableField.id`) to its new text. Text equal to the
    /// model's removes the edit. The original kept is the model's text, never an
    /// earlier edit, so a re-run compares against what the model wrote.
    ///
    /// `expected` is the model text each field had when the editor read it (by id). If
    /// the report was written again since, nothing is saved, so an edit typed for one
    /// item can't land on another. From the M5.1 deep review.
    static func saveEdits(base: URL, _ changes: [String: String], expected: [String: String]? = nil) throws {
        guard recordingExists(base: base) else { throw NotebookError.recordingGone }
        guard let report = loadReport(base: base) else { throw NotebookError.noReport }
        let available = Dictionary(uniqueKeysWithValues: editableFields(base: base).map { ($0.id, $0) })
        if let expected {
            for id in changes.keys {
                guard let f = available[id], expected[id] == f.modelText else { throw NotebookError.reportChanged }
            }
        }
        try editing(base: base) { edits in
            for (id, raw) in changes {
                guard let f = available[id] else { throw NotebookError.noSuchField }
                let text = f.isMultiline ? raw : oneLine(raw)
                guard text.count <= SummaryPipeline.maxFieldLength else {
                    throw NotebookError.tooLong(SummaryPipeline.maxFieldLength)
                }
                guard let s = report.sections.firstIndex(where: { $0.id == f.section }),
                    report.sections[s].items.indices.contains(f.item),
                    let model = f.field.get(report.sections[s].items[f.item])
                else { throw NotebookError.noSuchField }
                // An edit at this spot that still matches is the one being changed.
                edits.overrides.removeAll { e in
                    e.section == f.section && e.field == f.field
                        && place(of: e, in: report.sections[s]) == f.item
                }
                if text != model {
                    edits.overrides.append(
                        ContentEdit(
                            section: f.section, item: f.item, field: f.field, original: model, text: text,
                            itemText: f.field == .text ? nil : (report.sections[s].items[f.item].text ?? "")))
                }
            }
        }
    }

    static func staleEdits(base: URL) -> Int {
        guard let report = loadReport(base: base),
            let edits = try? ReportEdits.load(at: ReportEdits.url(forBase: base))
        else { return 0 }
        return apply(edits, to: report).stale.count
    }

    static func hasContentEdits(base: URL) -> Bool {
        !((try? ReportEdits.load(at: ReportEdits.url(forBase: base)))?.overrides.isEmpty ?? true)
    }

    /// Keep: each stale edit is put back over what is at its place now (its original
    /// becomes the model's current text there). An edit whose place is gone is dropped,
    /// because there's nothing to put it over. Drop: stale edits are removed. Edits that
    /// still match are untouched either way.
    static func resolveStale(base: URL, keep: Bool) throws {
        guard let report = loadReport(base: base) else { throw NotebookError.noReport }
        try editing(base: base) { edits in
            let stale = apply(edits, to: report).stale
            edits.overrides = edits.overrides.compactMap { e in
                guard stale.contains(e) else { return e }
                guard keep, let s = report.sections.firstIndex(where: { $0.id == e.section }),
                    report.sections[s].items.indices.contains(e.item),
                    let now = e.field.get(report.sections[s].items[e.item])
                else { return nil }
                var rebased = e
                rebased.original = now
                if e.field != .text { rebased.itemText = report.sections[s].items[e.item].text ?? "" }
                return now == e.text ? nil : rebased
            }
        }
    }

    /// After a re-run the user chose to drop: content edits go, the title and notes stay.
    static func dropContentEdits(base: URL) throws {
        try editing(base: base) { $0.overrides = [] }
    }

    // MARK: Files on disk

    /// The newest page in the sidecar's `reportFiles` is written again with the user's
    /// layer, so Finder and the terminal's Open show the edited report. Older pages came
    /// from earlier runs whose `report.json` is gone, so they are left as they were.
    static func rerenderLatestHTML(base: URL) {
        let dir = base.deletingLastPathComponent()
        guard let sidecar = RecordingSidecar.load(at: RecordingSidecar.url(forBase: base)),
            let name = sidecar.reportFiles?.last, isPlainHTMLName(name),
            !claimedByOthers(in: dir, except: base.lastPathComponent + sidecarSuffix).contains(name),
            let html = html(base: base)
        else { return }
        let url = dir.appendingPathComponent(name)
        guard isRegularFile(url) else { return }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Records a new report page in the sidecar, making a minimal sidecar when there is
    /// none (a `--summarize-only` on a loose `.txt`), so every report has a file list.
    /// A sidecar that exists but can't be read is left alone: rewriting it would lose
    /// its audio list. The page is then unrecorded, which delete reports.
    /// `hadReport` says a report was there before this write: if no page was recorded
    /// yet, that report's page is unrecorded, and the sidecar says so.
    static func recordReportFile(_ name: String, base: URL, now: Date = Date(), hadReport: Bool = false) {
        let url = RecordingSidecar.url(forBase: base)
        var sidecar: RecordingSidecar
        if FileManager.default.fileExists(atPath: url.path) {
            guard let loaded = RecordingSidecar.load(at: url) else { return }
            sidecar = loaded
        } else {
            sidecar = RecordingSidecar(createdAt: now, state: .processed)
        }
        if sidecar.reportFiles == nil, hadReport { sidecar.olderPagesUnrecorded = true }
        var files = sidecar.reportFiles ?? []
        if !files.contains(name) { files.append(name) }
        sidecar.reportFiles = files
        try? sidecar.save(to: url)
    }

    static func isPlainHTMLName(_ name: String) -> Bool {
        isPlainName(name) && (name as NSString).pathExtension.lowercased() == "html"
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.contains("\u{0}")
    }

    /// Not a folder, and not a link that could point outside.
    static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    private static func oneLine(_ s: String) -> String {
        // `\r\n` is one line break, not two (test writer, M5.1).
        s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func cut(_ s: String, _ max: Int) -> String { s.count <= max ? s : String(s.prefix(max)) }
}

// MARK: - Delete to the Trash

/// What a delete would move, and what it leaves and why. Make it with `Notebook.trashPlan`.
public struct TrashPlan: Sendable {
    /// In the order they go: everything else first, the sidecar last.
    public let files: [URL]
    /// Things the user should know, such as report pages that were never recorded.
    public let notes: [String]
}

extension Notebook {

    static let fixedSuffixes = [".txt", ".md", ".report.md", ".report.json", ".edits.json", ".notes.md"]
    private static let sidecarSuffix = ".mcmeta.json"

    /// Moves a file to the Trash; tests pass their own so they never touch the real one.
    typealias Remover = (URL) throws -> Void
    static let systemTrash: Remover = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The files a delete moves: the sidecar's `audioFiles` and `reportFiles`, the fixed
    /// names, then the sidecar. Never by matching names (D-44): each listed name must be
    /// a plain entry in this folder, a regular file, and not claimed by another recording.
    static func trashPlan(base: URL, busy: Set<String> = []) throws -> TrashPlan {
        let dir = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        guard !busy.contains(name) else { throw NotebookError.recordingInProgress }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let sidecarName = name + sidecarSuffix
        var sidecar: RecordingSidecar?
        if names.contains(sidecarName) {
            guard let loaded = RecordingSidecar.load(at: dir.appendingPathComponent(sidecarName)) else {
                throw NotebookError.sidecarUnreadable
            }
            if loaded.state == .recording {
                if let pid = loaded.pid, pid != getpid(), AudioRetention.isRunning(pid: pid) {
                    throw NotebookError.recordingInProgress
                }
                throw NotebookError.unfinished
            }
            sidecar = loaded
        }

        // What other recordings in this folder list, so a planted or damaged sidecar
        // can't take another recording's page or audio with it.
        let claimedByOthers = claimedByOthers(in: dir, except: sidecarName)

        var files: [String] = []
        var notes: [String] = []
        func add(_ file: String) {
            guard isPlainName(file), names.contains(file), !files.contains(file), file != sidecarName,
                !claimedByOthers.contains(file), isRegularFile(dir.appendingPathComponent(file))
            else { return }
            files.append(file)
        }
        for file in sidecar?.audioFiles ?? [] {
            let stem = (file as NSString).deletingPathExtension
            guard ["wav", "m4a"].contains((file as NSString).pathExtension.lowercased()),
                RecordingFiles.ownerBase(of: stem) == name,
                stem == name || !names.contains(stem + sidecarSuffix)
            else { continue }
            add(file)
        }
        for file in sidecar?.reportFiles ?? [] where isPlainHTMLName(file) { add(file) }
        for suffix in fixedSuffixes { add(name + suffix) }

        let hadReport = names.contains(name + ".report.json")
        if hadReport && sidecar?.reportFiles == nil || sidecar?.olderPagesUnrecorded == true {
            notes.append(
                "A report page written before pages were recorded (a dated .html file in \(dir.lastPathComponent)) isn't listed, so it's left. Delete it yourself if you don't want it."
            )
        }
        var urls = files.map { dir.appendingPathComponent($0) }
        if sidecar != nil, isRegularFile(dir.appendingPathComponent(sidecarName)) {
            urls.append(dir.appendingPathComponent(sidecarName))
        }
        return TrashPlan(files: urls, notes: notes)
    }

    /// Names the other sidecars in `dir` list as their audio or pages.
    static func claimedByOthers(in dir: URL, except sidecarName: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var claimed = Set<String>()
        for other in names where other.hasSuffix(sidecarSuffix) && other != sidecarName {
            guard let s = RecordingSidecar.load(at: dir.appendingPathComponent(other)) else { continue }
            claimed.formUnion(s.audioFiles ?? [])
            claimed.formUnion(s.reportFiles ?? [])
        }
        return claimed
    }

    /// Moves the plan's files to the Trash in order, the sidecar last, and stops at the
    /// first failure so the sidecar still lists what's left. Nothing is deleted for good.
    /// With `confirmed`, only files that are in both it and a fresh plan move, so nothing
    /// the user didn't see goes. From the M5.1 reviews.
    @discardableResult
    static func trash(
        base: URL, busy: Set<String> = [], confirmed: TrashPlan? = nil, remover: Remover = systemTrash
    ) throws -> TrashPlan {
        var plan = try trashPlan(base: base, busy: busy)
        if let confirmed {
            let seen = Set(confirmed.files.map(\.standardizedFileURL.path))
            plan = TrashPlan(files: plan.files.filter { seen.contains($0.standardizedFileURL.path) }, notes: plan.notes)
        }
        var moved: [URL] = []
        for url in plan.files {
            do { try remover(url) } catch {
                throw NotebookError.moveFailed(url.lastPathComponent, error.localizedDescription)
            }
            moved.append(url)
        }
        return TrashPlan(files: moved, notes: plan.notes)
    }
}
