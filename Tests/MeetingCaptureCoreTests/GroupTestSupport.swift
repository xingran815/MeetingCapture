import Foundation
import XCTest

@testable import MeetingCaptureCore

/// Shared setup for the M5.2 group tests (spec 05.2, D-94): recordings with a sidecar
/// (the `createdAt` that orders them), an invented report, optional notes and edits, in
/// the test's own temp folder. Nothing here touches the real Trash, config or network.
class GroupTestCase: NotebookTestCase {

    /// Markers planted in fields that must never leave the machine (excluded from the
    /// allow-list), and in fields that must go out.
    enum Mark {
        static let transcript = "ZQXTRANSCRIPTLINE"
        static let transcriptSpeaker = "ZQXTRANSCRIPTSPEAKER"
        static let suggestion = "ZQXSUGGESTION"
        static let quote = "ZQXQUOTE"
        static let reviewWhat = "ZQXREVIEWWHAT"
        static let reviewWhy = "ZQXREVIEWWHY"
        static let notice = "ZQXNOTICE"
        static let notesOff = "ZQXNOTESOFF"
        static let answer = "ZQXANSWER"
        static let owner = "ZQXOWNER"
        static let due = "ZQXDUE"
        static let speaker = "ZQXSPEAKER"
        static let reason = "ZQXREASON"
        static let sourceTitle = "ZQXSOURCETITLE"
        static let sourceURL = "ZQXSOURCEURL"
        static let modelTopic = "ZQXMODELTOPIC"
        static let replacedText = "ZQXREPLACEDTEXT"

        static let excluded = [
            transcript, transcriptSpeaker, suggestion, quote, reviewWhat, reviewWhy, notice, notesOff, answer, owner,
            due, speaker, reason, sourceTitle, sourceURL, modelTopic, replacedText,
        ]

        static let userTitle = "AllowedUserTitle"
        static let scenarioTitle = "AllowedScenarioTitle"
        static let sectionA = "AllowedSectionAlpha"
        static let sectionB = "AllowedSectionBeta"
        static let itemText = "AllowedItemText budget"
        static let itemDetail = "AllowedItemDetail"
        static let lowText = "AllowedLowItem"
        static let editedText = "AllowedEditedText"
        static let notesOn = "ZQXNOTESON"
    }

    let hour = 3600.0

    /// A past report with a distinct marker in every field the allow-list leaves out, and a
    /// recognisable value in each field it lets through.
    func markedReport() -> Report {
        var high = Report.Item(text: Mark.itemText)
        high.speaker = Mark.speaker
        high.quote = Mark.quote
        high.detail = Mark.itemDetail
        high.confidence = "sure"
        high.reason = Mark.reason
        high.source = "transcript"
        high.sources = [Report.Link(title: Mark.sourceTitle, url: "https://example.com/" + Mark.sourceURL)]
        high.priority = "high"
        high.keywords = ["budget"]
        var low = Report.Item(text: Mark.lowText)
        low.priority = "low"
        var action = Report.Item(text: Mark.replacedText)
        action.owner = Mark.owner
        action.due = Mark.due
        action.answer = Mark.answer
        return Report(
            topic: Mark.modelTopic, scenario: "meeting", scenarioTitle: Mark.scenarioTitle,
            createdAt: "2026-11-01T10:00:00Z", durationSeconds: 60, language: "en", models: .init(), reviewed: true,
            notices: [Mark.notice],
            sections: [
                Report.Section(id: "summary", title: Mark.sectionA, kind: .bullets, note: nil, items: [high, low]),
                Report.Section(id: "actions", title: Mark.sectionB, kind: .actions, note: nil, items: [action]),
            ],
            reviewChanges: [Report.Change(what: Mark.reviewWhat, why: Mark.reviewWhy)],
            transcript: [
                TranscriptEntry(
                    start: 1, end: 2, speaker: Mark.transcriptSpeaker, text: Mark.transcript,
                    suggestion: Mark.suggestion)
            ])
    }

    /// A small report with one summary item.
    func simpleReport(topic: String, text: String? = nil) -> Report {
        Report(
            topic: topic, scenario: "meeting", scenarioTitle: "Company meeting", createdAt: "2026-11-01T10:00:00Z",
            durationSeconds: 60, language: "en", models: .init(), reviewed: true, notices: [],
            sections: [
                Report.Section(
                    id: "summary", title: "Summary", kind: .prose, note: nil,
                    items: [Report.Item(text: text ?? "Summary of \(topic).")])
            ],
            reviewChanges: [], transcript: [])
    }

    /// A recording in the folder, recorded `hoursAgo` before `now`. Nil `report` leaves a
    /// recording with a sidecar and a transcript but no report yet.
    @discardableResult
    func addRecording(
        _ name: String, hoursAgo: Double, report: Report? = nil, edits: ReportEdits? = nil, notes: String? = nil
    ) throws -> URL {
        let date = now.addingTimeInterval(-hoursAgo * hour)
        try saveSidecar(
            name, RecordingSidecar(createdAt: date, state: .processed, transcribedAt: date, audioFiles: []))
        try "[00:00:01] You: hello\n".write(to: url(name + ".txt"), atomically: true, encoding: .utf8)
        let b = url(name)
        if let report { try JSONEncoder().encode(report).write(to: Notebook.reportURL(forBase: b)) }
        if let edits { try edits.save(to: ReportEdits.url(forBase: b)) }
        if let notes { try notes.write(to: Notebook.notesURL(forBase: b), atomically: true, encoding: .utf8) }
        return b
    }

    @discardableResult
    func makeGroup(_ members: [String], name: String = "Weekly team") throws -> ReportGroup {
        let g = try GroupStore.create(named: name, in: dir)
        for m in members { try GroupStore.add(m, to: g.id, in: dir) }
        return try XCTUnwrap(GroupStore.group(of: members.first ?? "", in: dir) ?? g)
    }

    func groupsFileBytes() throws -> Data { try Data(contentsOf: GroupStore.url(in: dir)) }

    // MARK: a backend that records what each step is sent

    /// Echoes the first email token it finds in a call's input in its reply, so a test can
    /// see the token being restored.
    func echoBackend() -> ScriptedBackend {
        func token(_ s: String) -> String {
            let re = try! NSRegularExpression(pattern: "<EMAIL_\\d+>")
            let ns = s as NSString
            return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range)
            }
                ?? ""
        }
        return ScriptedBackend(onComplete: { call in
            let t = token(call.input)
            let text = t.isEmpty ? "A summary." : "Write to \(t) today."
            switch call.tier {
            case .cheap: return Replies.classify("meeting")
            case .normal: return Replies.sections(["summary": [text]])
            case .frontier: return Replies.review(["summary": [text]])
            }
        })
    }

    /// Every call's system prompt and input, as one string.
    func everything(_ b: ScriptedBackend) -> String {
        (b.calls.map { $0.system + "\n" + $0.input } + b.searches.map { $0.joined(separator: "\n") }).joined(
            separator: "\n")
    }

    static func emailTokens(in text: String) -> [String] { NotebookLLMTests.emailTokens(in: text) }

    var transcriptText: String { "[00:00:05] You: let's start.\n[00:00:09] Speaker 1: ok" }
}
