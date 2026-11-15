import XCTest

@testable import MeetingCaptureCore

/// Tests that came from the M7 review's findings, each named after its finding.
/// Fake CLIs on PATH and a temp home: no model, no network.
final class M7ReviewFindingTests: XCTestCase {

    private var world: FakeCLIWorld!
    private var folder: URL!
    private var transcript: URL!

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

    /// Runs the job in a task that is already cancelled when it reaches the report step.
    private func runCancelled() async -> MeetingProcessor.Result {
        let processor = MeetingProcessor(config: Config())
        let url = transcript!
        return await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
            await withEnvironment("MEETINGCAPTURE_E2E", "1") {
                await withEnvironment("MEETINGCAPTURE_HOME", world.root.path) {
                    await withEnvironment("MEETINGCAPTURE_CLI_ONLY", "1") {
                        let task = Task { () -> MeetingProcessor.Result in
                            withUnsafeCurrentTask { $0?.cancel() }
                            return await processor.summarize(transcriptAt: url)
                        }
                        return await task.value
                    }
                }
            }
        }
    }

    /// Finding (M7 review): a cancelled job, or an Abort confirmed after the call ended,
    /// must never send the transcript to a model.
    /// The not-cancelled control is NotebookProcessorSlowTests
    /// .testARerunKeepsTitleAndNotesAndKeepsAnEditWhoseOriginalStillMatches (failure nil, pages written).
    func testFindingACancelledJobNeverSendsTheTranscriptToAModel() async throws {
        let result = await runCancelled()
        XCTAssertTrue(
            (result.failure ?? "").lowercased().contains("cancelled"), "failure: \(result.failure ?? "nil")")
        XCTAssertEqual(result.failedStage, .writingReport)
        XCTAssertEqual(world.calls(.claude).count, 0, "claude was never called")
        XCTAssertEqual(world.calls(.codex).count, 0, "codex was never called")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(written, ["m.txt"], "no report file was written; got \(written)")
    }

    /// Finding (M7 deep review): a cancel in the middle of a report makes no further model call.
    func testFindingCancelMidReportMakesNoFurtherModelCall() async throws {
        let backend = ScriptedBackend(onComplete: { call in
            withUnsafeCurrentTask { $0?.cancel() }
            return Replies.classify("meeting")
        })
        let pipeline = ReportFixtures.pipeline(backend)
        let text = try ReportFixtures.read("meeting", "transcript.txt")
        do {
            _ = try await Task { try await pipeline.run(transcript: text) }.value
            XCTFail("a cancelled run must not finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(backend.calls.count, 1, "only the classify call was made")
        XCTAssertEqual(backend.calls.first?.tier, .cheap)
        XCTAssertTrue(backend.searches.isEmpty)
    }
}
