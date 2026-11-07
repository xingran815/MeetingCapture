import XCTest

@testable import MeetingCaptureCore

/// Spec 05.2 / D-94 through the two real routes that write a report: the desktop's
/// `MeetingProcessor.summarize(transcriptAt:)` and the built CLI's `--summarize-only`,
/// both against fake CLIs on PATH, a temp home and a temp folder. No model, no network.
/// Slow because each run starts several processes.
final class GroupRoutesSlowTests: XCTestCase {

    private var world: FakeCLIWorld!
    private var folder: URL!
    private var transcript: URL!
    private var base: URL { transcript.deletingPathExtension() }

    private let earlierItem = "EarlierItemZQXALLOWED budget"
    private let transcriptMarker = "ZQXPASTTRANSCRIPTLINE"

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
        folder = world.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try world.installFixture("meeting")
        transcript = folder.appendingPathComponent("m.txt")
        try ReportFixtures.read("meeting", "transcript.txt").write(to: transcript, atomically: true, encoding: .utf8)
        try writeEarlierReport()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    /// An earlier recording `e` with a report, in a group with `m`.
    private func writeEarlierReport(pin: String? = nil) throws {
        let e = folder.appendingPathComponent("e")
        let date = Date().addingTimeInterval(-10 * 86_400)
        try RecordingSidecar(createdAt: date, state: .processed, transcribedAt: date, audioFiles: [])
            .save(to: RecordingSidecar.url(forBase: e))
        try "[00:00:01] You: hi\n".write(to: e.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        let report = Report(
            topic: "EarlierTopic", scenario: "meeting", scenarioTitle: "Company meeting",
            createdAt: "2026-11-01T10:00:00Z", durationSeconds: 60, language: "en", models: .init(), reviewed: true,
            notices: [],
            sections: [
                Report.Section(
                    id: "summary", title: "Summary", kind: .prose, note: nil, items: [Report.Item(text: earlierItem)])
            ],
            reviewChanges: [],
            transcript: [TranscriptEntry(start: 1, end: 2, speaker: "You", text: transcriptMarker)])
        try JSONEncoder().encode(report).write(to: Notebook.reportURL(forBase: e))
        let g = try GroupStore.create(named: "Weekly team", in: folder)
        try GroupStore.add("e", to: g.id, in: folder)
        try GroupStore.add("m", to: g.id, in: folder)
        if let pin { try GroupStore.setScenario(g.id, pin, catalog: .builtIn, in: folder) }
    }

    private func assertContextReached(_ calls: [FakeCLIWorld.Call], file: StaticString = #filePath, line: UInt = #line)
    {
        let withContext = calls.filter { $0.stdin.contains(SummaryPipeline.contextHeading) }
        XCTAssertEqual(withContext.count, 1, "only the sections call carries the context", file: file, line: line)
        XCTAssertTrue(
            withContext.first?.stdin.contains(earlierItem) ?? false, "the earlier item text", file: file, line: line)
        for c in calls {
            XCTAssertFalse(
                c.everything.contains(transcriptMarker), "a transcript marker reached a call", file: file, line: line)
        }
    }

    // MARK: (a) MeetingProcessor.summarize

    func testProcessorWritesAGroupedReportWithContextAndNotices() async throws {
        let processor = MeetingProcessor(config: Config())
        let result = await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
            await withEnvironment("MEETINGCAPTURE_E2E", "1") {
                await withEnvironment("MEETINGCAPTURE_HOME", world.root.path) {
                    await withEnvironment("MEETINGCAPTURE_CLI_ONLY", "1") {
                        await processor.summarize(transcriptAt: transcript, keepEdits: true)
                    }
                }
            }
        }
        XCTAssertNil(result.failure)
        let report = try XCTUnwrap(Notebook.loadReport(base: base), "report.json written")
        let notices = report.notices.joined(separator: "\n")
        XCTAssertTrue(notices.contains("\"EarlierTopic\""), notices)
        XCTAssertTrue(notices.contains("Weekly team"), notices)
        assertContextReached(world.calls(.claude))
        let reportFile = try String(contentsOf: Notebook.reportURL(forBase: base), encoding: .utf8)
        XCTAssertFalse(reportFile.contains(transcriptMarker))
    }

    func testProcessorWithoutAGroupSendsNoContext() async throws {
        try FileManager.default.removeItem(at: GroupStore.url(in: folder))
        let processor = MeetingProcessor(config: Config())
        let result = await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
            await withEnvironment("MEETINGCAPTURE_E2E", "1") {
                await withEnvironment("MEETINGCAPTURE_HOME", world.root.path) {
                    await withEnvironment("MEETINGCAPTURE_CLI_ONLY", "1") {
                        await processor.summarize(transcriptAt: transcript, keepEdits: true)
                    }
                }
            }
        }
        XCTAssertNil(result.failure)
        for c in world.calls(.claude) { XCTAssertFalse(c.everything.contains(earlierItem)) }
        XCTAssertFalse((Notebook.loadReport(base: base)?.notices ?? []).joined().contains("group"))
    }

    // MARK: (b) built CLI --summarize-only

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MeetingCaptureCLI")
    }

    private func cli(_ args: [String], limit: TimeInterval = 90) throws -> (status: Int32, out: String) {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MeetingCaptureCLI isn't built beside the tests: \(binary.path)")
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.currentDirectoryURL = world.root
        p.environment = [
            "PATH": world.bin.path + ":/usr/bin:/bin", "MEETINGCAPTURE_E2E": "1",
            "MEETINGCAPTURE_HOME": world.root.path, "HOME": world.root.path, "TMPDIR": world.root.path + "/",
            "USER": "tester",
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The fake claude answers `scenario`'s recorded sections and review (no classify), for runs that skip the classifier.
    private func installWithoutClassifier(_ scenario: String) throws {
        var replies = [try ReportFixtures.read(scenario, "sections.json")]
        if ReportFixtures.exists(scenario, "concepts.json") {
            replies.append(try ReportFixtures.read(scenario, "concepts.json"))
        }
        replies.append(try ReportFixtures.read(scenario, "review.json"))
        try world.install(.claude, answers: replies.map { FakeCLIWorld.jsonScript($0) })
    }

    private func usedClassifier() -> Bool {
        world.calls(.claude).contains { c in
            guard let i = c.args.firstIndex(of: "--model") else { return false }
            return c.args[i + 1] == "haiku"
        }
    }

    func testSummarizeOnlyUsesTheGroupsContextAndNamesItInTheReport() throws {
        let r = try cli(["--summarize-only", transcript.path])
        XCTAssertEqual(r.status, 0, r.out)
        let report = try XCTUnwrap(Notebook.loadReport(base: base), r.out)
        let notices = report.notices.joined(separator: "\n")
        XCTAssertTrue(notices.contains("\"EarlierTopic\""), notices)
        assertContextReached(world.calls(.claude))
        XCTAssertTrue(usedClassifier(), "no pin, so the classifier ran")
    }

    func testSummarizeOnlyUsesTheGroupsPinnedScenarioAndSkipsTheClassifier() throws {
        try FileManager.default.removeItem(at: GroupStore.url(in: folder))
        try writeEarlierReport(pin: "therapy")
        try installWithoutClassifier("therapy")
        let r = try cli(["--summarize-only", transcript.path])
        XCTAssertEqual(r.status, 0, r.out)
        let report = try XCTUnwrap(Notebook.loadReport(base: base), r.out)
        XCTAssertEqual(report.scenario, "therapy")
        XCTAssertFalse(usedClassifier())
        assertContextReached(world.calls(.claude))
    }

    func testTheScenarioFlagOverridesTheGroupsPin() throws {
        try FileManager.default.removeItem(at: GroupStore.url(in: folder))
        try writeEarlierReport(pin: "therapy")
        try installWithoutClassifier("lecture")
        let r = try cli(["--summarize-only", transcript.path, "--scenario", "lecture"])
        XCTAssertEqual(r.status, 0, r.out)
        let report = try XCTUnwrap(Notebook.loadReport(base: base), r.out)
        XCTAssertEqual(report.scenario, "lecture", "the flag, not the pin")
        XCTAssertFalse(usedClassifier())
        assertContextReached(world.calls(.claude))
    }
}
