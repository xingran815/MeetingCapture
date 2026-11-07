import XCTest

@testable import MeetingCaptureCore

/// Spec 05.1 Done-when: "A re-run keeps the title and notes, and keeps or drops edits as
/// chosen." Runs `MeetingProcessor.summarize` against fake CLIs on PATH and a temp home.
/// No model, no network. Slow because each run starts a few fake CLI processes.
final class NotebookProcessorSlowTests: XCTestCase {

    private var world: FakeCLIWorld!
    private var folder: URL!
    private var transcript: URL!
    private var base: URL { transcript.deletingPathExtension() }

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
        folder = world.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try world.installFixture("meeting")
        transcript = folder.appendingPathComponent("m.txt")
        try ReportFixtures.read("meeting", "transcript.txt").write(to: transcript, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func run(keepEdits: Bool = true) async -> MeetingProcessor.Result {
        let processor = MeetingProcessor(config: Config())
        return await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
            await withEnvironment("MEETINGCAPTURE_E2E", "1") {
                await withEnvironment("MEETINGCAPTURE_HOME", world.root.path) {
                    await withEnvironment("MEETINGCAPTURE_CLI_ONLY", "1") {
                        await processor.summarize(transcriptAt: transcript, keepEdits: keepEdits)
                    }
                }
            }
        }
    }

    private func entry() throws -> LibraryEntry {
        try XCTUnwrap(Library.entries(in: folder).first { $0.base.lastPathComponent == "m" })
    }

    func testARerunKeepsTitleAndNotesAndKeepsAnEditWhoseOriginalStillMatches() async throws {
        let first = await run()
        XCTAssertNil(first.failure)
        try entry().rename(to: "My title")
        try entry().saveNotes("my notes")
        try entry().saveEdits(["summary#0#text": "My own summary."])

        let second = await run(keepEdits: true)
        XCTAssertNil(second.failure)
        let e = try entry()
        XCTAssertEqual(e.topic, "My title")
        XCTAssertEqual(e.notes(), "my notes")
        XCTAssertTrue(e.hasContentEdits)
        let html = try XCTUnwrap(e.reportHTML())
        XCTAssertTrue(html.contains("My own summary.") && html.contains("<h1>My title</h1>"))
        XCTAssertEqual(
            try reportFilesPages(), 2, "each run left its own dated page, and the sidecar lists both")
    }

    func testARerunThatDropsEditsKeepsTitleAndNotes() async throws {
        _ = await run()
        try entry().rename(to: "My title")
        try entry().saveNotes("my notes")
        try entry().saveEdits(["summary#0#text": "My own summary."])

        let result = await run(keepEdits: false)
        XCTAssertNil(result.failure)
        let e = try entry()
        XCTAssertFalse(e.hasContentEdits)
        XCTAssertEqual(e.topic, "My title")
        XCTAssertEqual(e.notes(), "my notes")
        XCTAssertFalse(try XCTUnwrap(e.reportHTML()).contains("My own summary."))
    }

    func testARerunReportsAnEditWhoseOriginalChangedInsteadOfApplyingIt() async throws {
        _ = await run()
        try entry().saveEdits(["summary#0#text": "My own summary."])
        // The model "wrote" other words this time.
        var edits = try ReportEdits.load(at: ReportEdits.url(forBase: base))
        edits.overrides[0].original = "Words the model no longer writes."
        try edits.save(to: ReportEdits.url(forBase: base))

        _ = await run(keepEdits: true)
        let e = try entry()
        XCTAssertEqual(e.staleEditCount(), 1)
        let html = try XCTUnwrap(e.reportHTML())
        XCTAssertTrue(html.contains("no longer match"))
        XCTAssertFalse(html.contains("My own summary."))
    }

    func testNotesReachTheModelOnlyWhenTheSwitchIsOn() async throws {
        _ = await run()
        try entry().saveNotes("Zebra-cheese note, invented.")
        func notesCalls(after n: Int) -> Int {
            world.calls(.claude).dropFirst(n).filter { $0.everything.contains("Zebra-cheese") }.count
        }
        var before = world.calls(.claude).count
        _ = await run()
        XCTAssertEqual(notesCalls(after: before), 0, "off by default: nothing carries the notes")

        try entry().setSendNotesToLLM(true)
        before = world.calls(.claude).count
        _ = await run()
        XCTAssertEqual(notesCalls(after: before), 1, "only the sections call carries them")
    }

    private func reportFilesPages() throws -> Int {
        try XCTUnwrap(RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))?.reportFiles).count
    }
}
