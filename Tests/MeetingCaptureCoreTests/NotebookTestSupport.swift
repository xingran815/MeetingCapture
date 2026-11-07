import Foundation
import XCTest

@testable import MeetingCaptureCore

/// Shared setup for the M5.1 notebook tests: a recording called `meeting_20261107_100200`
/// in the test's own temp folder, with a small invented report. Nothing here touches the
/// real Trash, the real config or the network.
class NotebookTestCase: AudioTestCase {

    let recName = "meeting_20261107_100200"
    var base: URL { url(recName) }
    var edits: URL { ReportEdits.url(forBase: base) }
    var notes: URL { Notebook.notesURL(forBase: base) }

    /// A folder outside the recordings folder, for files a hostile sidecar might point at.
    var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("nb-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outside)
        try super.tearDownWithError()
    }

    func makeReport(
        topic: String = "Model topic", summary: String = "We ship on Friday.",
        actions: [String] = ["Write the spec", "Fix the bug", "Call the vendor"]
    ) -> Report {
        Report(
            topic: topic, scenario: "meeting", scenarioTitle: "Company meeting", createdAt: "2026-11-07T10:02:00Z",
            durationSeconds: 125, language: "en", models: .init(), reviewed: true, notices: [],
            sections: [
                Report.Section(
                    id: "summary", title: "Summary", kind: .prose, note: nil, items: [Report.Item(text: summary)]),
                Report.Section(
                    id: "actions", title: "Action items", kind: .actions, note: nil,
                    items: actions.map { Report.Item(text: $0, owner: "Ana", due: "Monday") }),
            ],
            reviewChanges: [], transcript: [TranscriptEntry(start: 1, end: 2, speaker: "You", text: "hello there")])
    }

    func writeReportJSON(_ report: Report) throws {
        try JSONEncoder().encode(report).write(to: Notebook.reportURL(forBase: base))
    }

    func loadEdits() throws -> ReportEdits { try ReportEdits.load(at: edits) }

    func bytes(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// A finished recording with a report, as the library would show it.
    func makeRecording(topic: String = "Model topic") throws {
        try writeReportJSON(makeReport(topic: topic))
        try "[00:00:01] You: hello\n".write(to: url(recName + ".txt"), atomically: true, encoding: .utf8)
    }

    /// Everything that is a recording's own, listed in its sidecar where the spec says it is.
    func makeFullRecording() throws {
        try makeRecording()
        for f in [
            recName + ".m4a", recName + "_clean.m4a", recName + "_part2.wav", recName + ".md",
            recName + ".report.md", recName + ".edits.json", recName + ".notes.md", "20261107_100200_Model_topic.html",
        ] { try touch(f, contents: Data("x".utf8)) }
        try saveSidecar(
            recName,
            RecordingSidecar(
                createdAt: now, state: .processed, transcribedAt: now,
                audioFiles: [recName + ".m4a", recName + "_clean.m4a", recName + "_part2.wav"],
                reportFiles: ["20261107_100200_Model_topic.html"]))
    }

    func page() -> Notebook.Page { Notebook.page(for: loadReportFromDisk(), base: base) }
    func loadReportFromDisk() -> Report { Notebook.loadReport(base: base)! }
}

let hostile = "<script>alert(1)</script> \"quoted\" 'single' <img src=x onerror=alert(2)> & more"
